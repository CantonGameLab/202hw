package event

import s3 "vendor:sdl3"

quit_requested: bool

// Dispatch a *single* event (used by the blocking main loop: the first event
// returned by WaitEventTimeout is handed to this).
// Both Update and the main loop share this proc -- event type classification
// lives here and only here, never duplicated.
Dispatch :: proc(e: ^s3.Event) {
	#partial switch e.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		quit_requested = true
	}
}

// Poll and apply every pending event; returns true = quit requested
// (the old name is kept for compatibility).
Poll :: proc() -> (quit: bool) {
	for e: s3.Event; s3.PollEvent(&e); {
		Dispatch(&e)
	}
	return quit_requested
}

// Quit requested (window close / QUIT).
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
