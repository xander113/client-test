package hub

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/vmihailenco/msgpack/v5"
	"pot.local/runtime/internal/place"
	"pot.local/runtime/internal/sim"
)

const (
	ticksPerSecond = 60
	maxClients     = 128
	roomCapacity   = 24
	inputWindow    = 600 * time.Millisecond
)

type Player struct {
	place.Point `msgpack:",inline"`
	ID          string  `msgpack:"id"`
	Name        string  `msgpack:"name"`
	Color       string  `msgpack:"color"`
	Yaw         float64 `msgpack:"yaw"`
}

type Event struct {
	Type    string   `msgpack:"type"`
	ID      string   `msgpack:"id,omitempty"`
	Players []Player `msgpack:"players,omitempty"`
	Message string   `msgpack:"message,omitempty"`
}

type member struct {
	socket  *websocket.Conn
	write   chan []byte
	done    chan struct{}
	once    sync.Once
	body    sim.Body
	profile Player
	input   sim.Input
	last    time.Time
	credit  float64
}

func (m *member) close() {
	m.once.Do(func() {
		close(m.done)
		_ = m.socket.Close()
	})
}

type room struct {
	world     *world
	space     sim.Space
	peers     map[*member]struct{}
	dirty     bool
	lastState time.Time
}

type sessions struct {
	mu      sync.Mutex
	rooms   map[string]*room
	clients int
	closed  bool
}

func (s *sessions) dropLocked(id string) {
	if room := s.rooms[id]; room != nil {
		for client := range room.peers {
			client.close()
			s.clients--
		}
		delete(s.rooms, id)
	}
}

func (s *sessions) changed(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.dropLocked(id)
}

func (s *sessions) run(ctx context.Context) {
	tick := time.NewTicker(time.Second / ticksPerSecond)
	defer tick.Stop()
	for count := uint64(0); ; count++ {
		select {
		case <-ctx.Done():
			s.mu.Lock()
			s.closed = true
			for id := range s.rooms {
				s.dropLocked(id)
			}
			s.mu.Unlock()
			return
		case now := <-tick.C:
			s.step(now, count%3 == 0)
		}
	}
}

func (s *sessions) step(now time.Time, broadcast bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, room := range s.rooms {
		for client := range room.peers {
			input := client.input
			if now.Sub(client.last) > inputWindow {
				input.X, input.Z = 0, 0
			}
			position, heading := client.body.Position, client.body.Heading
			room.space.Step(&client.body, input, 1.0/ticksPerSecond)
			room.dirty = room.dirty || position != client.body.Position || heading != client.body.Heading
		}
		if !broadcast || (!room.dirty && now.Sub(room.lastState) < time.Second) {
			continue
		}
		room.dirty, room.lastState = false, now
		event := Event{Type: "state", Players: make([]Player, 0, len(room.peers))}
		for client := range room.peers {
			player := client.profile
			p := client.body.Position
			player.Point = place.Point{X: p[0], Y: p[1], Z: p[2]}
			player.Yaw = client.body.Heading
			event.Players = append(event.Players, player)
		}
		packet, err := msgpack.Marshal(event)
		if err != nil {
			log.Printf("encode session state: %v", err)
			continue
		}
		for client := range room.peers {
			// If a network write is already pending, retain only the newest state.
			select {
			case <-client.write:
			default:
			}
			select {
			case client.write <- packet:
			default:
			}
		}
	}
}

// The handshake can wait on a remote socket. Keep it outside the simulation lock.
func (s *sessions) join(w http.ResponseWriter, r *http.Request, item *world, origin string) {
	id := item.place.ID
	s.mu.Lock()
	roomState := s.rooms[id]
	closed := s.closed || s.clients >= maxClients
	full := roomState != nil && roomState.world.revision == item.revision && len(roomState.peers) >= roomCapacity
	s.mu.Unlock()
	if closed || full {
		fail(w, http.StatusServiceUnavailable, "this play session is full")
		return
	}
	upgrader := websocket.Upgrader{
		HandshakeTimeout: 3 * time.Second,
		CheckOrigin: func(r *http.Request) bool {
			value := r.Header.Get("Origin")
			return value == "" || value == origin
		},
	}
	connection, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	roomState = s.rooms[id]
	if s.closed || s.clients >= maxClients || (roomState != nil && len(roomState.peers) >= roomCapacity) {
		_ = connection.Close()
		return
	}
	if roomState != nil && roomState.world.revision != item.revision {
		s.dropLocked(id)
		roomState = nil
	}
	if roomState == nil {
		roomState = &room{world: item, space: sim.Compile(item.place), peers: make(map[*member]struct{})}
		s.rooms[id] = roomState
	}
	var token [16]byte
	if _, err := rand.Read(token[:]); err != nil {
		_ = connection.Close()
		return
	}
	guest := hex.EncodeToString(token[:])
	colors := []string{"#09b734", "#206ae0", "#8058df", "#d77120", "#d14876", "#148f8f"}
	client := &member{
		socket: connection, write: make(chan []byte, 1), done: make(chan struct{}),
		profile: Player{ID: guest, Name: "Guest " + guest[:4], Color: colors[int(token[0])%len(colors)]},
		body:    roomState.space.Spawn(), credit: 40,
	}
	roomState.peers[client] = struct{}{}
	roomState.dirty = true
	s.clients++
	go s.serve(id, roomState, client)
}

func (s *sessions) serve(id string, room *room, client *member) {
	defer func() {
		client.close()
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.rooms[id] == room {
			delete(room.peers, client)
			room.dirty = true
			s.clients--
			if len(room.peers) == 0 {
				delete(s.rooms, id)
			}
		}
	}()
	connection := client.socket
	welcome, err := msgpack.Marshal(Event{Type: "welcome", ID: client.profile.ID})
	if err != nil {
		return
	}
	go client.send(welcome)
	connection.SetReadLimit(512)
	_ = connection.SetReadDeadline(time.Now().Add(25 * time.Second))
	connection.SetPongHandler(func(string) error {
		return connection.SetReadDeadline(time.Now().Add(25 * time.Second))
	})
	arrived := time.Now()
	for {
		kind, bytes, err := connection.ReadMessage()
		if err != nil {
			return
		}
		var input sim.Input
		if kind != websocket.BinaryMessage || place.Unpack(bytes, &input) != nil || !input.Valid() {
			return
		}
		now := time.Now()
		s.mu.Lock()
		client.credit = min(40, client.credit+now.Sub(arrived).Seconds()*40)
		arrived = now
		flood := client.credit < 1
		if !flood {
			client.credit--
			client.input = input
			client.last = now
		}
		s.mu.Unlock()
		if flood {
			return
		}
	}
}

func (m *member) send(welcome []byte) {
	defer m.close()
	write := func(kind int, packet []byte) error {
		if err := m.socket.SetWriteDeadline(time.Now().Add(3 * time.Second)); err != nil {
			return err
		}
		return m.socket.WriteMessage(kind, packet)
	}
	if err := write(websocket.BinaryMessage, welcome); err != nil {
		return
	}
	heartbeat := time.NewTicker(10 * time.Second)
	defer heartbeat.Stop()
	for {
		var err error
		select {
		case <-m.done:
			return
		case packet := <-m.write:
			err = write(websocket.BinaryMessage, packet)
		case <-heartbeat.C:
			err = write(websocket.PingMessage, nil)
		}
		if err != nil && !errors.Is(err, context.Canceled) {
			return
		}
	}
}

func (e Event) Valid() bool {
	switch e.Type {
	case "welcome":
		return place.ValidID(e.ID)
	case "state":
		if len(e.Players) > roomCapacity {
			return false
		}
		for _, p := range e.Players {
			if !place.ValidID(p.ID) || len(p.Name) > 80 || !place.ValidColor(p.Color) ||
				!place.InRange(p.X, -320, 320) || !place.InRange(p.Y, -40, 380) ||
				!place.InRange(p.Z, -320, 320) || !place.InRange(p.Yaw, -3.142, 3.142) {
				return false
			}
		}
		return true
	default:
		return false
	}
}
