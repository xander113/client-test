// Package desktop owns the native application data and network connection behind the Electron shell.
package desktop

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/vmihailenco/msgpack/v5"
	"pot.local/runtime/internal/hub"
	"pot.local/runtime/internal/place"
	"pot.local/runtime/internal/sim"
)

const maxFrame = 2 << 20

type request struct {
	ID     uint32       `msgpack:"id"`
	Window uint32       `msgpack:"window"`
	Action string       `msgpack:"action"`
	World  string       `msgpack:"world"`
	Path   string       `msgpack:"path"`
	Scene  *place.Place `msgpack:"scene"`
	Input  sim.Input    `msgpack:"input"`
}

type packet struct {
	ID     uint32     `msgpack:"id,omitempty"`
	Value  any        `msgpack:"value,omitempty"`
	Error  string     `msgpack:"error,omitempty"`
	Window uint32     `msgpack:"window,omitempty"`
	Event  *hub.Event `msgpack:"event,omitempty"`
}

type pipe struct {
	writer io.Writer
	mu     sync.Mutex
}

func (p *pipe) send(message packet) {
	data, err := msgpack.Marshal(message)
	if err != nil || len(data) > maxFrame {
		return
	}
	out := make([]byte, 4+len(data))
	binary.BigEndian.PutUint32(out[:4], uint32(len(data)))
	copy(out[4:], data)
	p.mu.Lock()
	defer p.mu.Unlock()
	_, _ = p.writer.Write(out)
}

func read(reader io.Reader) (request, error) {
	var req request
	var count [4]byte
	if _, err := io.ReadFull(reader, count[:]); err != nil {
		return req, err
	}
	size := binary.BigEndian.Uint32(count[:])
	if size == 0 || size > maxFrame {
		return req, errors.New("invalid Pot message size")
	}
	data := make([]byte, size)
	if _, err := io.ReadFull(reader, data); err != nil {
		return req, err
	}
	err := place.Unpack(data, &req)
	return req, err
}

type link struct {
	input chan sim.Input
	stop  context.CancelFunc
}

type bridge struct {
	network *hub.API
	mode    string
	out     pipe
	mu      sync.Mutex
	active  map[uint32]*link
}

func (b *bridge) leave(window uint32) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if active := b.active[window]; active != nil {
		delete(b.active, window)
		active.stop()
	}
}

func (b *bridge) forward(window uint32, input sim.Input) {
	if !input.Valid() {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if active := b.active[window]; active != nil {
		select {
		case <-active.input:
		default:
		}
		active.input <- input
	}
}

func (b *bridge) join(ctx context.Context, window uint32, id string) error {
	ctx, stop := context.WithCancel(ctx)
	current := &link{make(chan sim.Input, 1), stop}
	b.mu.Lock()
	if previous := b.active[window]; previous != nil {
		previous.stop()
	}
	b.active[window] = current
	b.mu.Unlock()

	joined := false
	defer func() {
		if !joined {
			b.mu.Lock()
			if b.active[window] == current {
				delete(b.active, window)
			}
			b.mu.Unlock()
			stop()
		}
	}()
	connection, err := b.network.Connect(ctx, id)
	if err != nil {
		return err
	}
	go func() {
		<-ctx.Done()
		_ = connection.Close()
	}()
	_ = connection.SetReadDeadline(time.Now().Add(7 * time.Second))
	event, err := readEvent(connection)
	if err != nil || event.Type != "welcome" || ctx.Err() != nil {
		return errors.New("the world service did not start the session")
	}
	_ = connection.SetReadDeadline(time.Time{})
	b.out.send(packet{Window: window, Event: &event})
	joined = true

	go func() {
		defer stop()
		for {
			select {
			case <-ctx.Done():
				return
			case input := <-current.input:
				data, err := msgpack.Marshal(input)
				if err != nil {
					return
				}
				_ = connection.SetWriteDeadline(time.Now().Add(2 * time.Second))
				if connection.WriteMessage(websocket.BinaryMessage, data) != nil {
					return
				}
			}
		}
	}()
	go func() {
		defer stop()
		for {
			_ = connection.SetReadDeadline(time.Now().Add(16 * time.Second))
			event, err := readEvent(connection)
			if err != nil {
				break
			}
			if event.Type == "state" && ctx.Err() == nil {
				b.out.send(packet{Window: window, Event: &event})
			}
		}
		b.mu.Lock()
		same := b.active[window] == current
		if same {
			delete(b.active, window)
		}
		b.mu.Unlock()
		if same {
			b.out.send(packet{Window: window, Event: &hub.Event{Type: "closed", Message: "The session ended."}})
		}
	}()
	return nil
}

func readEvent(conn *websocket.Conn) (hub.Event, error) {
	var event hub.Event
	kind, data, err := conn.ReadMessage()
	if err != nil {
		return event, err
	}
	if kind != websocket.BinaryMessage || place.Unpack(data, &event) != nil || !event.Valid() {
		return event, errors.New("the service sent an invalid session packet")
	}
	return event, nil
}

func (b *bridge) act(ctx context.Context, req request) (any, error) {
	switch req.Action {
	case "mode":
		return b.mode, nil
	case "sample":
		samples, err := place.Samples()
		if err != nil {
			return nil, err
		}
		return samples[0], nil
	case "worlds":
		return b.network.List(ctx)
	case "load":
		return b.network.Load(ctx, req.World)
	case "thumbnail":
		return b.network.Preview(ctx, req.World)
	case "open":
		return place.Load(req.Path)
	case "save":
		if req.Scene == nil || !strings.EqualFold(filepath.Ext(req.Path), ".pot") {
			return nil, errors.New("choose a .pot project filename")
		}
		return true, place.Save(req.Path, req.Scene)
	case "publish":
		if req.Scene == nil {
			return nil, errors.New("no Pot project to publish")
		}
		return b.network.Publish(ctx, req.Scene)
	case "join":
		return nil, b.join(ctx, req.Window, req.World)
	case "leave":
		b.leave(req.Window)
		return nil, nil
	default:
		return nil, errors.New("unknown Pot action")
	}
}

func Credential() (string, error) {
	var secure [32]byte
	_, err := rand.Read(secure[:])
	return hex.EncodeToString(secure[:]), err
}

func Run(reader io.Reader, writer io.Writer) error {
	key, err := Credential()
	if err != nil {
		return err
	}
	render, err := hub.StartRender("127.0.0.1:0", key)
	if err != nil {
		return err
	}
	defer render.Close()
	local, err := hub.StartWorlds(hub.Config{
		Address: "127.0.0.1:0", DataDir: os.Getenv("POT_LOCAL_DATA_DIR"),
		ReadToken: key, WriteToken: key, RenderURL: render.URL, RenderToken: key,
	})
	if err != nil {
		return err
	}
	defer local.Close()
	api, err := hub.NewAPI(local.URL, key, key)
	if err != nil {
		return err
	}
	b := &bridge{network: api, mode: "local", out: pipe{writer: writer}, active: make(map[uint32]*link)}
	ctx, cancel := context.WithCancel(context.Background())
	var pending sync.WaitGroup
	defer func() {
		cancel()
		pending.Wait()
	}()
	b.configure(ctx, os.Getenv("POT_API_ENDPOINT"))
	capacity := make(chan struct{}, 16)
	for {
		req, err := read(reader)
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("could not read from the desktop shell: %w", err)
		}
		if req.Action == "input" {
			b.forward(req.Window, req.Input)
			continue
		}
		if req.Action == "leave" {
			b.leave(req.Window)
			if req.ID != 0 {
				b.out.send(packet{ID: req.ID})
			}
			continue
		}
		if req.ID == 0 {
			continue
		}
		select {
		case capacity <- struct{}{}:
			pending.Add(1)
			go func() {
				defer pending.Done()
				defer func() { <-capacity }()
				value, err := b.act(ctx, req)
				result := packet{ID: req.ID, Value: value}
				if err != nil {
					result.Error, result.Value = err.Error(), nil
				}
				b.out.send(result)
			}()
		default:
			b.out.send(packet{ID: req.ID, Error: "Pot is busy. Try again."})
		}
	}
}

func (b *bridge) configure(parent context.Context, endpoint string) {
	if endpoint == "" {
		return
	}
	ctx, cancel := context.WithTimeout(parent, 2*time.Second)
	defer cancel()
	api, err := hub.NewAPI(endpoint, os.Getenv("POT_API_READ_TOKEN"), os.Getenv("POT_API_WRITE_TOKEN"))
	if err == nil {
		_, err = api.List(ctx)
	}
	if err != nil {
		log.Print("hosted library is unavailable, using local Pot services")
		return
	}
	b.network, b.mode = api, "hosted"
}
