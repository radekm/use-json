module ujson::list{Type};

import std;

// Doesn't panic when OOM.
struct SList
{
    Type* data;
    usz cap;
    usz count;
    Allocator allocator;
}

fn void SList.init(&self, Allocator allocator)
{
    *self = {};
    self.allocator = allocator;
}

fn usz SList.len(&self) @operator(len)
{
    return self.count;
}

fn Type SList.get(&self, usz at) @operator([])
{
    return self.data[:self.count][at];
}

fn Type* SList.get_ref(&self, usz at) @operator(&[])
{
    return &self.data[:self.count][at];
}

fn Type SList.pop(&self)
{
    if (self.count == 0) abort("Empty list");
    return self.data[--self.count];
}

fn void? SList.push(&self, Type item)
{
    if (self.count == self.cap)
    {
        usz next_cap = max(self.cap * 2, 8);
        if (next_cap <= self.cap) abort("Capacity overflowed");
        // `realloc_try` works correctly even if the previous pointer was `null`.
        self.data = allocator::realloc_try(self.allocator, self.data, Type.sizeof * next_cap)!;
        self.cap = next_cap;
    }

    self.data[self.count++] = item;
}

fn void SList.free(&self)
{
    allocator::free(self.allocator, self.data);
    *self = {};
}
