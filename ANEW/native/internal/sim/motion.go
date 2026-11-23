// Package sim advances avatar motion on a fixed server clock from bounded inputs.
package sim

import (
	"math"

	"pot.local/runtime/internal/place"
)

const (
	Radius   = 0.3
	Height   = 1.65
	StepSize = 0.25
	Speed    = 6.5
	Jump     = 8.2
	Gravity  = 22
	epsilon  = 0.001
)

type Input struct {
	X    float64 `msgpack:"x"` // Strafe.
	Z    float64 `msgpack:"z"` // Forward.
	Yaw  float64 `msgpack:"yaw"`
	Jump uint32  `msgpack:"jump"` // Increases once per press.
}

func (i Input) Valid() bool {
	return place.InRange(i.X, -1, 1) && place.InRange(i.Z, -1, 1) && place.InRange(i.Yaw, -math.Pi, math.Pi)
}

type Body struct {
	Position place.Vec3
	Heading  float64
	Velocity float64
	Grounded bool
	LastJump uint32
}

type box struct {
	min, max place.Vec3
}

type Space struct {
	spawn     place.Vec3
	respawn   float64
	colliders []box
}

func Compile(p *place.Place) Space {
	var space Space
	space.spawn = place.Vec3{p.Spawn.X, p.Spawn.Y, p.Spawn.Z}
	bottom := p.Spawn.Y
	for _, part := range p.Parts {
		half := place.HalfBounds(part)
		bounds := box{
			min: place.Vec3{part.Position[0] - half[0], part.Position[1] - half[1], part.Position[2] - half[2]},
			max: place.Vec3{part.Position[0] + half[0], part.Position[1] + half[1], part.Position[2] + half[2]},
		}
		bottom = math.Min(bottom, bounds.min[1])
		if part.Solid {
			space.colliders = append(space.colliders, bounds)
		}
	}
	space.respawn = math.Max(-40, bottom-24)
	return space
}

func (s Space) reset(b *Body) {
	b.Position = s.spawn
	for _, box := range s.colliders {
		if box.footprint(b.Position) && box.vertical(b.Position[1]) {
			b.Position[1] = math.Max(b.Position[1], box.max[1])
		}
	}
	b.Velocity, b.Grounded = 0, false
}

func (s Space) Spawn() Body {
	var body Body
	s.reset(&body)
	return body
}

func (b box) footprint(p place.Vec3) bool {
	return p[0]+Radius > b.min[0] && p[0]-Radius < b.max[0] &&
		p[2]+Radius > b.min[2] && p[2]-Radius < b.max[2]
}

func (b box) vertical(feet float64) bool {
	return feet+Height > b.min[1]+epsilon && feet < b.max[1]-epsilon
}

func (s Space) horizontal(b *Body, axis int, distance float64) {
	if distance == 0 {
		return
	}
	p := &b.Position
	previous := p[axis]
	p[axis] = math.Max(-320+Radius, math.Min(320-Radius, previous+distance))
	cross := 2 - axis
	for _, box := range s.colliders {
		if !box.vertical(p[1]) || p[cross]+Radius <= box.min[cross] || p[cross]-Radius >= box.max[cross] {
			continue
		}
		near := box.min[axis] - Radius
		crossed := previous <= near && p[axis] > near
		if distance < 0 {
			near = box.max[axis] + Radius
			crossed = previous >= near && p[axis] < near
		}
		if !crossed {
			continue
		}
		top := box.max[1]
		canStep := b.Grounded && top-p[1] <= StepSize
		if canStep {
			for _, other := range s.colliders {
				if other.vertical(top) && other.footprint(*p) {
					canStep = false
					break
				}
			}
		}
		if canStep {
			p[1] = top
		} else {
			p[axis] = near
		}
	}
}

func (s Space) Step(b *Body, input Input, dt float64) {
	if input.X != 0 || input.Z != 0 {
		sine, cosine := math.Sincos(input.Yaw)
		x := input.X*cosine - input.Z*sine
		z := -input.X*sine - input.Z*cosine
		speed := Speed * dt / math.Max(1, math.Hypot(x, z))
		s.horizontal(b, 0, x*speed)
		s.horizontal(b, 2, z*speed)
		b.Heading = math.Atan2(-x, -z)
	}
	if b.LastJump != input.Jump {
		if b.Grounded {
			b.Velocity = Jump
		}
		b.LastJump = input.Jump
	}

	p := &b.Position
	b.Velocity -= Gravity * dt
	original := p[1] + b.Velocity*dt
	next := original
	b.Grounded = false
	for _, box := range s.colliders {
		if !box.footprint(*p) {
			continue
		}
		if b.Velocity <= 0 && p[1] >= box.max[1]-epsilon && next <= box.max[1] {
			next = box.max[1]
			b.Grounded = true
		} else if b.Velocity > 0 && p[1]+Height <= box.min[1] && next+Height >= box.min[1] {
			next = box.min[1] - Height
		}
	}
	if b.Grounded || (b.Velocity > 0 && next < original) {
		b.Velocity = 0
	}
	p[1] = next
	if p[1] < s.respawn {
		s.reset(b)
	}
}
