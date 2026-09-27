package memory

RefCounted :: struct ($N : int, $T : typeid) { // for the id == 0 we see it as a null just like a null
	data : [N]T,
	refs : [N]u32,
	pool : [N]u32,

	on_load : [N]b8,

	count : u32,
	next : u32,
}

RefLoad :: proc(rc : ^RefCounted($N, $T), value : T) -> u32 {
	if rc.count > 0 {
		id := rc.pool[rc.count - 1]
		rc.count -= 1

		rc.data[id] = value
		rc.on_load[id] = true
		return id
	}

	if rc.next + 1 < u32(N) {
		id := rc.next + 1
		rc.next += 1

		rc.data[id] = value
		rc.on_load[id] = true
		return id
	}

	return 0
}

RcGet :: proc(rc : ^RefCounted($N, $T), id : u32) -> ^T {
	if !rc.on_load[id] {
		return nil
	}
	return &rc.data[id]
}

RefUnload :: proc(rc : ^RefCounted($N, $T), id : u32) -> b8 {
	if rc.refs[id] > 0 || !rc.on_load[id] {
		//have some one use the resource report an error!
		return false
	}
	
	rc.on_load[id] = false
	rc.data[id] = {}
	rc.pool[rc.count] = id
	rc.count += 1
	return true
}

RefRetain :: proc(rc : ^RefCounted($N, $T), id : u32) -> b8 {
	if !rc.on_load[id] {
		return false
	}

	rc.refs[id] += 1

	return true
}

RefUnretain :: proc(rc : ^RefCounted($N, $T), id : u32) -> b8 {
	if !rc.on_load[id] {
		return false
	}

	rc.refs[id] -= 1

	return true
}
