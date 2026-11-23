package sim

import (
	"math"
	"testing"

	"pot.local/runtime/internal/place"
)

func TestControlInputRespectsRotatedCollisionAndJump(t *testing.T) {
	p := &place.Place{Parts: []place.Part{
		{Position: place.Vec3{0, -1, 0}, Size: place.Vec3{30, 2, 30}, Solid: true},
		{Position: place.Vec3{0, 1.5, -3}, Rotation: place.Vec3{0, 90, 0}, Size: place.Vec3{1, 3, 12}, Solid: true},
	}}
	world := Compile(p)
	body := world.Spawn()
	for range 100 {
		world.Step(&body, Input{Z: 1}, 1.0/60)
	}
	if math.Abs(body.Position[2]+2.2) > 0.01 || !body.Grounded {
		t.Fatalf("walk crossed the wall or stopped short: %#v", body)
	}
	world.Step(&body, Input{Jump: 1}, 1.0/60)
	if body.Position[1] <= 0 || body.Velocity <= 0 {
		t.Fatal("new jump input did not lift character")
	}
	for range 120 {
		world.Step(&body, Input{Jump: 1}, 1.0/60)
	}
	if !body.Grounded || body.Position[1] != 0 {
		t.Fatal("the same jump input fired more than once")
	}
}
