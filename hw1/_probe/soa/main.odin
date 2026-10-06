package main

import "core:fmt"

// Does the #soa layout let a field's base address be taken, the way the renderer does with
// `&point_lights.position`? The shadow upload takes that address and hands it to glUniform3fv
// as a flat float array, so whether it is a legal expression decides what a per-node light
// could even look like.
Light :: struct {
	position : [3]f32,
	intensity : f32,
	pivot_node : u32,
}

lights : #soa[4]Light

main :: proc() {
	p := &lights.position
	fmt.println("&lights.position        ->", rawptr(p), " first =", p[0])

	q := &lights.pivot_node
	fmt.println("&lights.pivot_node      ->", rawptr(q), " first =", q[0])

	fmt.println("lights.position[1]      =", lights.position[1])
	fmt.println("lights.pivot_node[1]    =", lights.pivot_node[1])
	fmt.println("lights[1].position      =", lights[1].position)
	fmt.println("lights[1].pivot_node    =", lights[1].pivot_node)
	fmt.println("size_of(Light)          =", size_of(Light))
	fmt.println("distance between the two field arrays:", uintptr(rawptr(q)) - uintptr(rawptr(p)))
}
