package main

import "core:fmt"

Entity :: struct {
	position : [3]f32,
}

entities : [20]Entity

Door :: struct {
	entity_index : u32,
}
