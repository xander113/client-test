package hub

import (
	"bytes"
	"context"
	"image/png"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/vmihailenco/msgpack/v5"
	"pot.local/runtime/internal/place"
	"pot.local/runtime/internal/sim"
)

func TestBinaryWorldPipeline(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	render, err := StartRender("127.0.0.1:0", "renderer-secret")
	if err != nil {
		t.Fatal(err)
	}
	defer render.Close()
	directory := t.TempDir()
	config := Config{Address: "127.0.0.1:0", DataDir: directory, ReadToken: "member",
		WriteToken: "operator", RenderURL: render.URL, RenderToken: "renderer-secret"}
	host, err := StartWorlds(config)
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close()
	mirror, err := StartWorlds(config)
	if err != nil {
		t.Fatal(err)
	}
	defer mirror.Close()
	studio, _ := NewAPI(host.URL, "member", "operator")
	player, _ := NewAPI(mirror.URL, "member", "")
	guest, _ := NewAPI(mirror.URL, "", "")
	if _, err = guest.List(ctx); err == nil {
		t.Fatal("private catalog allowed an unauthenticated read")
	}
	items, err := player.List(ctx)
	if err != nil || len(items) != 3 {
		t.Fatal("starter catalog:", items, err)
	}
	scene, err := studio.Load(ctx, items[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	scene.ID = "rotated-place"
	scene.Parts[1].Rotation[1] = 27
	if _, err = studio.Publish(ctx, scene); err != nil {
		t.Fatal(err)
	}
	if saved, err := place.Load(filepath.Join(directory, "world-rotated-place.pot")); err != nil || saved.Parts[1].Rotation[1] != 27 {
		t.Fatal("catalog did not persist binary rotation", err)
	}
	copy, err := player.Load(ctx, scene.ID)
	if err != nil || copy.Parts[1].Rotation[1] != 27 {
		t.Fatal("second app did not see the published world", err)
	}
	if _, err = player.Publish(ctx, scene); err == nil {
		t.Fatal("unauthorized destination accepted publish")
	}
	preview, err := player.Preview(ctx, scene.ID)
	if err != nil {
		t.Fatal(err)
	}
	dimension, err := png.DecodeConfig(bytes.NewReader(preview))
	if err != nil || dimension.Width != 480 || dimension.Height != 270 {
		t.Fatal("PRS returned an invalid thumbnail", err)
	}
	scene.Parts[1].Rotation[1] = -32
	if _, err = studio.Publish(ctx, scene); err != nil {
		t.Fatal(err)
	}
	rotated, err := player.Preview(ctx, scene.ID)
	if err != nil || bytes.Equal(preview, rotated) {
		t.Fatal("preview did not reflect published rotation", err)
	}

	linkA, err := player.Connect(ctx, scene.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer linkA.Close()
	a := packet(t, linkA, "welcome")
	linkB, err := player.Connect(ctx, scene.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer linkB.Close()
	b := packet(t, linkB, "welcome")
	if a.ID == b.ID {
		t.Fatal("sessions shared the same identity")
	}
	var before Player
	for {
		state := packet(t, linkB, "state")
		if len(state.Players) == 2 {
			for _, peer := range state.Players {
				if peer.ID == a.ID {
					before = peer
				}
			}
			break
		}
	}
	motion, _ := msgpack.Marshal(sim.Input{X: 1})
	if err = linkA.WriteMessage(websocket.BinaryMessage, motion); err != nil {
		t.Fatal(err)
	}
	for {
		state := packet(t, linkB, "state")
		for _, peer := range state.Players {
			if peer.ID == a.ID && peer.X > before.X+0.25 {
				return
			}
		}
	}
}

func packet(t *testing.T, c *websocket.Conn, kind string) Event {
	t.Helper()
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	for {
		frame, data, err := c.ReadMessage()
		var event Event
		if err != nil || frame != websocket.BinaryMessage || place.Unpack(data, &event) != nil || !event.Valid() {
			t.Fatalf("missing binary %s event: %v, %#v", kind, err, event)
		}
		if event.Type == kind {
			return event
		}
	}
}

func TestBoundedUploadsAndEndpoint(t *testing.T) {
	server, err := StartRender("127.0.0.1:0", "render-secret")
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	request, err := http.NewRequest(http.MethodPost, server.URL+"/v2/render", strings.NewReader(strings.Repeat("X", place.MaxSize+1)))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", place.MIME)
	request.Header.Set("Authorization", "Bearer render-secret")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatal("oversized project status", response.StatusCode)
	}
	if _, err := Endpoint("http://world.example.net"); err == nil {
		t.Fatal("allowed HTTP for a hosted service")
	}
	if endpoint, err := Endpoint("https://world.example.net/pot"); err != nil ||
		endpoint.JoinPath("v2/worlds").Path != "/pot/v2/worlds" {
		t.Fatal("lost hosted endpoint prefix")
	}
}
