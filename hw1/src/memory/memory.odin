package memory

Array :: struct ($N : u32, $T : typeid) {
	data : [N]T,
	pool : [N]u32,
	in_use : [N]b8,
	count : u32,
	next : u32,
}

ArrayAlloc :: proc(arr : ^Array($N, $T)) -> (id : u32) {
	if arr.count > 0 {
		id = arr.pool[arr.count - 1]
		arr.count -= 1
	}
	else if arr.next + 1 < N {
		arr.next += 1
		id = arr.next
	}
	if id == 0 {
		return
	}
	arr.in_use[id] = true
	return
}

ArrayGet :: proc(arr : ^Array($N, $T), id : u32) -> ^T {
	if id >= N || !arr.in_use[id] {
		return nil
	}
	return &arr.data[id]
}

ArrayFree :: proc(arr : ^Array($N, $T), id : u32) -> b8 {
	if ArrayGet(arr, id) == nil{
		return false
	}
	arr.data[id] = {}
	arr.in_use[id] = false
	arr.pool[arr.count] = id
	arr.count += 1
	return true
}

GenArray :: struct ($N : u32, $T : typeid) {
	data : [N]T,
	generations : [N]u8,
	pool : [N]u32,
	in_use : [N]b8,
	count : u32,
	next : u32,
}

GenHandle :: struct {
	id : u32,
	generation : u32,
}

GenAlloc :: proc(ga : ^GenArray($N, $T)) -> GenHandle {
	id : u32 = 0
	if ga.count > 0 {
		id = ga.pool[ga.count - 1]
		ga.count -= 1
	} else if ga.next + 1 < N {
		id = ga.next + 1
		ga.next += 1
	}
	if id == 0 {
		return {}
	}
	ga.in_use[id] = true
	return { id = id, generation = ga.generations[id]}
}

GenGet :: proc(ga : ^GenArray($N, $T), handle : GenHandle) -> ^T {
	if handle.id >= N || !ga.in_use[handle.id] || ga.generations[handle.id] != handle.generation {
		return nil
	}
	return &ga.data[handle.id]
}

GenFree :: proc(ga : ^GenArray($N, $T), handle : GenHandle) -> b8 {
	if GenGet(ga, handle) == nil{
		return false
	}
	ga.data[handle.id] = {}
	ga.generations[handle.id] += 1
	ga.in_use[handle.id] = false
	ga.pool[ga.count] = id
	ga.count += 1
	return true
}

RefCounted :: struct ($N : u32, $T : typeid) { // for the id == 0 we see it as a null just like a null
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

	if rc.next + 1 < N {
		id := rc.next + 1
		rc.next += 1

		rc.data[id] = value
		rc.on_load[id] = true
		return id
	}

	return 0
}

RefGet :: proc(rc : ^RefCounted($N, $T), id : u32) -> ^T {
	if id >= N || !rc.on_load[id] {
		return nil
	}
	return &rc.data[id]
}

Ref :: proc(rc : ^RefCounted($N, $T), id : u32) -> (ref : u32) {
	if id >= N || !rc.on_load[id] {
		return N
	}
	return rc.refs[id]
}

RefUnload :: proc(rc : ^RefCounted($N, $T), id : u32) -> b8 {
	if id >= N || rc.refs[id] > 0 || !rc.on_load[id] {
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
	if id >= N || !rc.on_load[id] || rc.refs[id] <= 0 {
		return false
	}
	rc.refs[id] += 1
	return true
}

RefUnretain :: proc(rc : ^RefCounted($N, $T), id : u32) -> b8 {
	if  id >= N || !rc.on_load[id] {
		return false
	}
	rc.refs[id] -= 1
	return true
}
