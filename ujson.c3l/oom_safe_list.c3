module ujson::list{Type};

import std;

// Doesn't panic when OOM.
struct SList
{
    Type* data;
    usz cap;
    usz count;
}

fn usz SList.len(&self) @operator(len)
{
    return self.count;
}

fn Type* SList.get(&self, usz at) @operator(&[])
{
    return &self.data[at];
}

fn Type SList.pop(&self)
{
    if (self.count == 0) abort("Empty list");
    return self.data[--self.count];
}

fn void? SList.push(&self, Type item, Allocator allocator)
{
    if (self.count == self.cap)
    {
        usz next_cap = max(self.cap * 2, 8);
        if (next_cap <= self.cap) abort("Capacity overflowed");
        // `realloc_try` works correctly even if the previous pointer was `null`.
        self.data = allocator::realloc_try(allocator, self.data, Type.sizeof * next_cap)!;
        self.cap = next_cap;
    }

    self.data[self.count++] = item;
}

fn void SList.free(&self, Allocator allocator)
{
    allocator::free(allocator, self.data);
    *self = {};
}
