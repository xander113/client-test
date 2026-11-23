// Package place defines the authored world shared by Studio, play servers and PRS.
package place

import (
	"bytes"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf16"
	"unicode/utf8"

	"github.com/vmihailenco/msgpack/v5"
)

const (
	MaxSize  = 256 << 10
	MaxParts = 400
	Version  = 2
	MIME     = "application/msgpack"
)

var (
	fileHeader = []byte{'P', 'O', 'T', 0, 1}
	idPattern  = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,63}$`)
	rgbPattern = regexp.MustCompile(`^#[0-9a-fA-F]{6}$`)
)

type Vec3 [3]float64

type Point struct {
	X float64 `msgpack:"x" json:"x"`
	Y float64 `msgpack:"y" json:"y"`
	Z float64 `msgpack:"z" json:"z"`
}

type Part struct {
	ID       string `msgpack:"id" json:"id"`
	Name     string `msgpack:"name" json:"name"`
	Kind     string `msgpack:"kind" json:"kind"`
	Position Vec3   `msgpack:"position" json:"position"`
	Rotation Vec3   `msgpack:"rotation" json:"rotation"` // XYZ Euler angles in degrees.
	Size     Vec3   `msgpack:"size" json:"size"`
	Color    string `msgpack:"color" json:"color"`
	Solid    bool   `msgpack:"solid" json:"solid"`
}

type Place struct {
	Version     int    `msgpack:"schemaVersion" json:"schemaVersion"`
	ID          string `msgpack:"id" json:"id"`
	Name        string `msgpack:"name" json:"name"`
	Description string `msgpack:"description" json:"description"`
	Spawn       Point  `msgpack:"spawn" json:"spawn"`
	Parts       []Part `msgpack:"objects" json:"objects"`
}

type Summary struct {
	ID          string `msgpack:"id"`
	Name        string `msgpack:"name"`
	Description string `msgpack:"description"`
}

func (p Place) Summary() Summary {
	return Summary{p.ID, p.Name, p.Description}
}

func ValidID(id string) bool { return idPattern.MatchString(id) }

func ValidColor(color string) bool { return rgbPattern.MatchString(color) }

func InRange(v, lo, hi float64) bool { return v >= lo && v <= hi }

func validPosition(v Vec3) bool {
	return InRange(v[0], -250, 250) && InRange(v[1], -40, 250) && InRange(v[2], -250, 250)
}

func validText(s string, required bool, limit int) bool {
	return utf8.ValidString(s) && len(utf16.Encode([]rune(s))) <= limit &&
		(!required || strings.TrimSpace(s) != "") &&
		!strings.ContainsFunc(s, func(r rune) bool { return r < 32 || r == unicode.MaxASCII })
}

func (p *Place) Validate() error {
	if p.Version != Version {
		return errors.New("unsupported Pot project format")
	}
	if !ValidID(p.ID) || !validText(p.Name, true, 80) || !validText(p.Description, false, 400) {
		return errors.New("invalid project name, ID, or description")
	}
	if !validPosition(Vec3{p.Spawn.X, p.Spawn.Y, p.Spawn.Z}) {
		return errors.New("spawn is outside the world bounds")
	}
	if p.Parts == nil || len(p.Parts) > MaxParts {
		return fmt.Errorf("a project must contain a list of up to %d parts", MaxParts)
	}
	seen := make(map[string]struct{}, len(p.Parts))
	for i := range p.Parts {
		part := &p.Parts[i]
		if _, exists := seen[part.ID]; exists {
			return errors.New("part IDs must be unique")
		}
		seen[part.ID] = struct{}{}
		if !ValidID(part.ID) || !validText(part.Name, true, 80) || !ValidColor(part.Color) {
			return fmt.Errorf("invalid part metadata at row %d", i+1)
		}
		switch part.Kind {
		case "box", "sphere", "cylinder":
		default:
			return fmt.Errorf("unsupported geometry for %s", part.Name)
		}
		if !validPosition(part.Position) {
			return fmt.Errorf("%s is outside the world bounds", part.Name)
		}
		for axis, size := range part.Size {
			if !InRange(size, 0.1, 128) || !InRange(part.Rotation[axis], -180, 180) {
				return fmt.Errorf("%s has invalid dimensions or rotation", part.Name)
			}
		}
		part.Color = strings.ToLower(part.Color)
	}
	return nil
}

func Unpack(data []byte, destination any) error {
	reader := bytes.NewReader(data)
	if err := msgpack.NewDecoder(reader).Decode(destination); err != nil {
		return err
	}
	if reader.Len() != 0 {
		return errors.New("unexpected data after Pot packet")
	}
	return nil
}

func FromWire(data []byte) (*Place, error) {
	var p Place
	if len(data) > MaxSize {
		return nil, errors.New("Pot project exceeds its size limit")
	}
	if err := Unpack(data, &p); err != nil {
		return nil, fmt.Errorf("invalid binary project: %w", err)
	}
	if err := p.Validate(); err != nil {
		return nil, err
	}
	return &p, nil
}

func (p *Place) Marshal() ([]byte, error) {
	copy := *p
	copy.Parts = append(make([]Part, 0, len(p.Parts)), p.Parts...)
	if p.Parts == nil {
		return nil, errors.New("project has no part list")
	}
	if err := copy.Validate(); err != nil {
		return nil, err
	}
	content, err := msgpack.Marshal(&copy)
	if len(content)+len(fileHeader) > MaxSize {
		return nil, errors.New("Pot project exceeds its size limit")
	}
	return content, err
}

func decodeFile(data []byte) (*Place, error) {
	if bytes.HasPrefix(data, fileHeader) {
		return FromWire(data[len(fileHeader):])
	}
	data = bytes.TrimSpace(bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf}))
	if !bytes.HasPrefix(data, []byte{'{'}) {
		return nil, errors.New("this file is not a supported Pot project")
	}
	// Retain a read-only import path for projects from the first Pot release.
	var p Place
	if err := json.Unmarshal(data, &p); err != nil || p.Version != 1 {
		return nil, errors.New("could not import the legacy Pot project")
	}
	p.Version = Version
	return &p, p.Validate()
}

func Load(path string) (*Place, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > MaxSize {
		return nil, errors.New("project must be a regular file within the size limit")
	}
	data, err := io.ReadAll(io.LimitReader(f, MaxSize+1))
	if err != nil {
		return nil, err
	}
	if len(data) > MaxSize {
		return nil, errors.New("project exceeds the size limit")
	}
	return decodeFile(data)
}

func Save(path string, p *Place) error {
	data, err := p.Marshal()
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".pot-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err = tmp.Write(append(append([]byte{}, fileHeader...), data...)); err == nil {
		err = tmp.Sync()
	}
	closeErr := tmp.Close()
	if err = errors.Join(err, closeErr); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

//go:embed samples/*.pot
var samples embed.FS

func Samples() ([]*Place, error) {
	var worlds []*Place
	for _, id := range []string{"terrace-park", "dune-circuit", "tidebreak"} {
		data, err := samples.ReadFile("samples/" + id + ".pot")
		if err != nil {
			return nil, err
		}
		p, err := decodeFile(data)
		if err != nil {
			return nil, err
		}
		worlds = append(worlds, p)
	}
	return worlds, nil
}

// Rotation uses the same XYZ order as the viewport. Its columns are the part's local axes.
func Rotation(deg Vec3) [3]Vec3 {
	x, y, z := deg[0]*math.Pi/180, deg[1]*math.Pi/180, deg[2]*math.Pi/180
	a, b, c, d, e, f := math.Cos(x), math.Sin(x), math.Cos(y), math.Sin(y), math.Cos(z), math.Sin(z)
	return [3]Vec3{{c * e, a*f + b*e*d, b*f - a*e*d}, {-c * f, a*e - b*f*d, b*e + a*f*d}, {d, -b * c, a * c}}
}

func Rotate(m [3]Vec3, v Vec3) Vec3 {
	return Vec3{m[0][0]*v[0] + m[1][0]*v[1] + m[2][0]*v[2],
		m[0][1]*v[0] + m[1][1]*v[1] + m[2][1]*v[2],
		m[0][2]*v[0] + m[1][2]*v[1] + m[2][2]*v[2]}
}

func HalfBounds(part Part) Vec3 {
	m := Rotation(part.Rotation)
	var half Vec3
	for i := range half {
		for j := range m {
			half[i] += math.Abs(m[j][i]) * part.Size[j] / 2
		}
	}
	return half
}
