// Package thumb creates PNG previews from the same authored data used by the world runtime.
package thumb

import (
	"bytes"
	"context"
	"image"
	"image/png"
	"math"
	"sort"
	"strconv"

	"pot.local/runtime/internal/place"
)

const (
	width        = 480
	height       = 270
	rasterWidth  = width * 2
	rasterHeight = height * 2
)

type vec = place.Vec3

func dot(a, b vec) float64 { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2] }

func unit(a vec) vec {
	n := math.Sqrt(dot(a, a))
	return vec{a[0] / n, a[1] / n, a[2] / n}
}

func cross(a, b vec) vec {
	return vec{a[1]*b[2] - a[2]*b[1], a[2]*b[0] - a[0]*b[2], a[0]*b[1] - a[1]*b[0]}
}

var (
	camera = unit(vec{0.61, 0.53, 0.73})
	right  = unit(vec{camera[2], 0, -camera[0]})
	up     = cross(camera, right)
	light  = unit(vec{-0.3, 0.85, 0.45})
)

type vertex struct {
	position vec
	normal   vec
}

type mesh struct {
	vertices  []vertex
	triangles [][3]int
}

func (m *mesh) quad(a, b, c, d vertex) {
	i := len(m.vertices)
	m.vertices = append(m.vertices, a, b, c, d)
	m.triangles = append(m.triangles, [3]int{i, i + 1, i + 2}, [3]int{i, i + 2, i + 3})
}

func cube() mesh {
	var m mesh
	for axis := range 3 {
		for _, direction := range []float64{-1, 1} {
			var corners [4]vertex
			for i, pair := range [4][2]float64{{-0.5, -0.5}, {0.5, -0.5}, {0.5, 0.5}, {-0.5, 0.5}} {
				var v vertex
				v.position[axis], v.normal[axis] = direction*0.5, direction
				v.position[(axis+1)%3], v.position[(axis+2)%3] = pair[0], pair[1]
				corners[i] = v
			}
			m.quad(corners[0], corners[1], corners[2], corners[3])
		}
	}
	return m
}

func sphere(segments, stacks int) mesh {
	var m mesh
	for row := 0; row <= stacks; row++ {
		latitude := (float64(row)/float64(stacks) - 0.5) * math.Pi
		r, y := math.Cos(latitude), math.Sin(latitude)
		for column := range segments {
			s, c := math.Sincos(float64(column) * 2 * math.Pi / float64(segments))
			n := vec{r * c, y, r * s}
			m.vertices = append(m.vertices, vertex{vec{n[0] / 2, n[1] / 2, n[2] / 2}, n})
			if row == 0 {
				continue
			}
			a := (row-1)*segments + column
			b := (row-1)*segments + (column+1)%segments
			if row > 1 {
				m.triangles = append(m.triangles, [3]int{a, b, a + segments})
			}
			if row < stacks {
				m.triangles = append(m.triangles, [3]int{b, b + segments, a + segments})
			}
		}
	}
	return m
}

func cylinder(segments int) mesh {
	var m mesh
	edge := func(i int, y float64, face bool) vertex {
		s, c := math.Sincos(float64(i) * 2 * math.Pi / float64(segments))
		normal := vec{c, 0, s}
		if face {
			normal = vec{0, y * 2, 0}
		}
		return vertex{vec{c / 2, y, s / 2}, normal}
	}
	for i := range segments {
		m.quad(edge(i, 0.5, false), edge(i, -0.5, false), edge(i+1, -0.5, false), edge(i+1, 0.5, false))
		for _, y := range []float64{-0.5, 0.5} {
			index := len(m.vertices)
			m.vertices = append(m.vertices, vertex{vec{0, y, 0}, vec{0, y * 2, 0}}, edge(i, y, true), edge(i+1, y, true))
			m.triangles = append(m.triangles, [3]int{index, index + 1, index + 2})
		}
	}
	return m
}

var meshes = map[string]mesh{"box": cube(), "sphere": sphere(22, 14), "cylinder": cylinder(24)}

type projection struct {
	x, y, scale float64
}

func fit(p *place.Place) projection {
	spawn := vec{p.Spawn.X, p.Spawn.Y, p.Spawn.Z}
	minX, minY := dot(spawn, right), dot(spawn, up)
	maxX, maxY := minX, minY
	for _, part := range p.Parts {
		x, y := dot(part.Position, right), dot(part.Position, up)
		var radiusX, radiusY float64
		for axis, vector := range place.Rotation(part.Rotation) {
			radiusX += math.Abs(dot(vector, right)) * part.Size[axis] / 2
			radiusY += math.Abs(dot(vector, up)) * part.Size[axis] / 2
		}
		minX, maxX = math.Min(minX, x-radiusX), math.Max(maxX, x+radiusX)
		minY, maxY = math.Min(minY, y-radiusY), math.Max(maxY, y+radiusY)
	}
	return projection{
		(minX + maxX) / 2, (minY + maxY) / 2,
		math.Min(rasterWidth*0.88/math.Max(8, maxX-minX), rasterHeight*0.82/math.Max(6, maxY-minY)),
	}
}

type frame struct {
	image *image.NRGBA
	depth []float32
}

func newFrame() frame {
	f := frame{image.NewNRGBA(image.Rect(0, 0, rasterWidth, rasterHeight)), make([]float32, rasterWidth*rasterHeight)}
	for i := range f.depth {
		f.depth[i] = float32(math.Inf(-1))
		f.image.Pix[i*4] = 238
		f.image.Pix[i*4+1] = 244
		f.image.Pix[i*4+2] = 239
		f.image.Pix[i*4+3] = 255
	}
	return f
}

type point struct {
	x, y, depth, shade, facing float64
}

func (f frame) triangle(a, b, c point, rgb vec) {
	dx1, dy1 := b.x-a.x, b.y-a.y
	dx2, dy2 := c.x-a.x, c.y-a.y
	area := dx1*dy2 - dy1*dx2
	if math.Abs(area) < 0.001 {
		return
	}
	x0 := max(0, int(math.Floor(min(a.x, b.x, c.x))))
	y0 := max(0, int(math.Floor(min(a.y, b.y, c.y))))
	x1 := min(rasterWidth-1, int(math.Ceil(max(a.x, b.x, c.x))))
	y1 := min(rasterHeight-1, int(math.Ceil(max(a.y, b.y, c.y))))
	bstep, cstep := dy2/area, -dy1/area
	bdepth, cdepth := b.depth-a.depth, c.depth-a.depth
	bshade, cshade := b.shade-a.shade, c.shade-a.shade
	for y := y0; y <= y1; y++ {
		xoff, yoff := float64(x0)+0.5-a.x, float64(y)+0.5-a.y
		wb, wc := (xoff*dy2-yoff*dx2)/area, (dx1*yoff-xoff*dy1)/area
		for x := x0; x <= x1; x++ {
			if wb >= -1e-7 && wc >= -1e-7 && wb+wc <= 1.0000001 {
				depth := float32(a.depth + bdepth*wb + cdepth*wc)
				index := y*rasterWidth + x
				if depth > f.depth[index] {
					f.depth[index] = depth
					shade := a.shade + bshade*wb + cshade*wc
					for channel := range 3 {
						f.image.Pix[index*4+channel] = uint8(min(255, rgb[channel]*shade+7))
					}
				}
			}
			wb, wc = wb+bstep, wc+cstep
		}
	}
}

func (f frame) draw(part place.Part, pr projection, points []point) {
	geometry := meshes[part.Kind]
	n, _ := strconv.ParseUint(part.Color[1:], 16, 24)
	rgb := vec{float64(n >> 16), float64((n >> 8) & 255), float64(n & 255)}
	rotation := place.Rotation(part.Rotation)
	for i, vert := range geometry.vertices {
		pos, normal := vert.position, vert.normal
		for axis := range 3 {
			pos[axis] *= part.Size[axis]
			normal[axis] /= part.Size[axis]
		}
		pos, normal = place.Rotate(rotation, pos), unit(place.Rotate(rotation, normal))
		for axis := range 3 {
			pos[axis] += part.Position[axis]
		}
		points[i] = point{
			rasterWidth/2 + (dot(pos, right)-pr.x)*pr.scale,
			rasterHeight/2 - (dot(pos, up)-pr.y)*pr.scale,
			dot(pos, camera), 0.61 + 0.43*max(0, dot(normal, light)), dot(normal, camera),
		}
	}
	for _, t := range geometry.triangles {
		a, b, c := points[t[0]], points[t[1]], points[t[2]]
		if a.facing > 0 || b.facing > 0 || c.facing > 0 {
			f.triangle(a, b, c, rgb)
		}
	}
}

func Render(ctx context.Context, p *place.Place) ([]byte, error) {
	pr, f := fit(p), newFrame()
	parts := append([]place.Part(nil), p.Parts...)
	sort.SliceStable(parts, func(i, j int) bool { return dot(parts[i].Position, camera) > dot(parts[j].Position, camera) })
	points := make([]point, len(meshes["sphere"].vertices))
	for _, part := range parts {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		f.draw(part, pr, points)
	}
	preview := image.NewNRGBA(image.Rect(0, 0, width, height))
	pixels := f.image.Pix
	stride := f.image.Stride
	for y := range height {
		for x := range width {
			src, dst := y*2*stride+x*8, y*preview.Stride+x*4
			for c := range 3 {
				i := src + c
				preview.Pix[dst+c] = uint8((int(pixels[i]) + int(pixels[i+4]) + int(pixels[i+stride]) + int(pixels[i+stride+4])) / 4)
			}
			preview.Pix[dst+3] = 255
		}
	}
	var data bytes.Buffer
	encoder := png.Encoder{CompressionLevel: png.BestSpeed}
	if err := encoder.Encode(&data, preview); err != nil {
		return nil, err
	}
	return data.Bytes(), nil
}
