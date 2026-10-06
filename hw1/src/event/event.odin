package event

import s3 "vendor:sdl3"

quit_requested: bool

MAX_SCANCODE_COUNT :: 512

InputState :: struct {
	key_down : [MAX_SCANCODE_COUNT]b8,
	key_pressed : [MAX_SCANCODE_COUNT]b8,
	key_released : [MAX_SCANCODE_COUNT]b8,
}

Input_State : InputState
Focus_Lost : b8

Poll :: proc() -> bool {
	for e: s3.Event; s3.PollEvent(&e); {
		#partial switch e.type {
		case .QUIT, .WINDOW_CLOSE_REQUESTED:
			quit_requested = true
		case .KEY_UP, .KEY_DOWN:

			key_index := i32(e.key.scancode)
			if key_index < 0 || key_index >= MAX_SCANCODE_COUNT do continue

			if e.key.down {
				Input_State.key_down[key_index] = true
				if !e.key.repeat {
					Input_State.key_pressed[key_index] = true
				}
			} else {
				Input_State.key_down[key_index] = false
				if !e.key.repeat {
					Input_State.key_released[key_index] = true
				}
			}

			case .WINDOW_FOCUS_LOST:
				Focus_Lost = true

			case .WINDOW_FOCUS_GAINED:
				Focus_Lost = false
		}
	}
	return quit_requested
}

FlushInputState :: proc() {
	for index in 0..<MAX_SCANCODE_COUNT {
		Input_State.key_released[index] = false
		//Input_State.key_down[index] = false
		Input_State.key_pressed[index] = false
	}
}

QuitRequested :: proc() -> bool {
	return quit_requested
}

RelevantEventsPending :: proc() -> bool {
	return s3.HasEvents(.QUIT, .WINDOW_CLOSE_REQUESTED) ||
	       s3.HasEvents(.WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_PIXEL_SIZE_CHANGED) ||
	       s3.HasEvents(.KEY_DOWN, .KEY_UP) ||
	       s3.HasEvents(.TEXT_INPUT, .TEXT_INPUT) ||
	       s3.HasEvents(.MOUSE_MOTION, .MOUSE_WHEEL)
}
