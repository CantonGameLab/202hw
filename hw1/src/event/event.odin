package event

import s3 "vendor:sdl3"

quit_requested: bool

// 派发**单个**事件(阻塞式主循环用:WaitEventTimeout 拿到的首个事件交给这里)。
// Update 与主循环共用本函数 —— 事件类型的判定只此一处,不重复。
Dispatch :: proc(e: ^s3.Event) {
	#partial switch e.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		quit_requested = true
	}
}

// 轮询并应用全部事件;返回 true = 请求退出(兼容旧名)
Poll :: proc() -> (quit: bool) {
	for e: s3.Event; s3.PollEvent(&e); {
		Dispatch(&e)
	}
	return quit_requested
}

// 退出请求(窗口关闭/QUIT)
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
