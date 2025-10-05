module use_json;

import std;

// `EconomyArenaAllocator` is similar to classic `ArenaAllocator` but it doesn't store any metadata for allocations.
// This means that each allocation needs less space but it's impossible to implement `release` and `resize`
// because we don't know sizes of allocations. So the only way to free some memory is by `reset` or `clear`.
struct EconomyArenaAllocator (Allocator)
{
    char[] data;
    usz used;
}

fn EconomyArenaAllocator* EconomyArenaAllocator.init(&self, char[] data)
{
    self.data = data;
    self.used = 0;
    return self;
}

fn void EconomyArenaAllocator.clear(&self)
{
    self.used = 0;
}

macro EconomyArenaAllocator* wrap(char[] bytes)
{
    return (EconomyArenaAllocator){}.init(bytes);
}

fn usz EconomyArenaAllocator.mark(&self) => self.used;

fn void EconomyArenaAllocator.reset(&self, usz mark) => self.used = mark;

<*
 No-op.

 @require ptr != null
*>
fn void EconomyArenaAllocator.release(&self, void* ptr, bool) @dynamic
{
    assert((uptr)ptr >= (uptr)self.data.ptr, "Pointer originates from a different allocator");
}

<*
 Allocates a fresh memory.

 @require !alignment || math::is_power_of_2(alignment)
 @require alignment <= mem::MAX_MEMORY_ALIGNMENT : `alignment too big`
 @require size > 0
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? EconomyArenaAllocator.acquire(&self, usz size, AllocInitType init_type, usz alignment) @dynamic
{
    usz total_len = self.data.len;
    if (size > total_len) return mem::INVALID_ALLOC_SIZE?;
    alignment = allocator::alignment_for_allocation(alignment);
    void* start_mem = self.data.ptr;
    void* unaligned_pointer_to_offset = start_mem + self.used;
    void* mem = mem::aligned_pointer(unaligned_pointer_to_offset, alignment);
    usz end = (usz)(mem - self.data.ptr) + size;
    if (end > total_len) return mem::OUT_OF_MEMORY?;
    self.used = end;
    if (init_type == ZERO) mem::clear(mem, size, mem::DEFAULT_MEM_ALIGNMENT);
    return mem;
}

<*
 Not supported.

 @require !alignment || math::is_power_of_2(alignment)
 @require alignment <= mem::MAX_MEMORY_ALIGNMENT : `alignment too big`
 @require old_ptr != null
 @require size > 0
 @return? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? EconomyArenaAllocator.resize(&self, void* old_ptr, usz size, usz alignment) @dynamic
{
    assert((uptr)old_ptr >= (uptr)self.data.ptr, "Pointer originates from a different allocator");
    // We can't copy the old data to the new memory because we don't know the size of the original allocation.
    abort("EconomyArenaAllocator does not support resize");
}
