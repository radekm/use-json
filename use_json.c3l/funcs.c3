module use_json;

import std;
import libc;
import btree;

fn UJsonValue make_value(void* ptr, UJsonValueKind kind)
{
    return { .ptr_with_kind = (uptr)ptr | (uptr)kind };
}

fn void* UJsonValue.ptr(self)
{
    return (void*)(self.ptr_with_kind & ~((uptr)7));
}

fn UJsonValueKind UJsonValue.kind(self)
{
    return (UJsonValueKind)(self.ptr_with_kind & 7);
}

fn UJsonCursor UJsonParsed.to_cursor(&self, ArenaAllocator* arena)
{
    UJsonPosition* pos = allocator::new(arena, UJsonPosition);
    pos.value = self.root;
    return {
        .arena = arena,
        .data = self.data,
        .pos = pos,
    };
}

faultdef
    INVALID_POSITION_KIND,
    INVALID_VALUE_KIND,
    FIELDS_WITH_DUPLICATE_KEY,
    UNUSED_FIELD,
    ALREADY_USED_KEY;

fn bool? UJsonCursor.non_null(&self)
{
    if (self.pos.kind != VALUE) return INVALID_POSITION_KIND?;
    return self.pos.value.kind() != NULL;
}

fn bool? UJsonCursor.get_bool(&self)
{
    if (self.pos.kind != VALUE) return INVALID_POSITION_KIND?;
    switch (self.pos.value.kind())
    {
        case FALSE: return false;
        case TRUE: return true;
        default: return INVALID_VALUE_KIND?;
    }
}

fn String? UJsonCursor.get_string(&self)
{
    if (self.pos.kind != VALUE) return INVALID_POSITION_KIND?;
    if (self.pos.value.kind() != STRING) return INVALID_VALUE_KIND?;

    UJsonString* string = self.pos.value.ptr();
    UJsonRange range = string.range;
    return self.data[range.start:range.len];
}

fn String? UJsonCursor.get_number_as_string(&self)
{
    if (self.pos.kind != VALUE) return INVALID_POSITION_KIND?;
    if (self.pos.value.kind() != NUMBER) return INVALID_VALUE_KIND?;

    UJsonNumber* number = self.pos.value.ptr();
    UJsonRange range = number.range;
    return self.data[range.start:range.len];
}

fn void? UJsonCursor.begin_list(&self)
{
    if (self.pos.kind != VALUE) return INVALID_POSITION_KIND?;
    if (self.pos.value.kind() != LIST) return INVALID_VALUE_KIND?;

    usz arena_mark = self.arena.mark();
    bool done;
    // Revert everything to the original state if something fails.
    defer if (!done) self.arena.reset(arena_mark);

    UJsonPosition* new_pos = allocator::new_try(self.arena, UJsonPosition)!;
    new_pos.arena_mark = arena_mark;
    new_pos.prev_pos = self.pos;
    new_pos.value = self.pos.value;  // Value hasn't changed yet.
    new_pos.kind = LIST;

    done = true;
    self.pos = new_pos;
}

fn UJsonPosition*? UJsonCursor.find_closest_pos(&self, UJsonPositionKind kind, UJsonPosition** out_child) @local
{
    UJsonPosition* pos = self.pos;
    UJsonPosition* child = null;
    while (pos != null)
    {
        if (pos.kind == kind)
        {
            if (out_child != null) *out_child = child;
            return pos;
        }
        // Every kind of position except `VALUE` must be properly ended
        // by calling one of `end_list`, `end_dict` or `end_dict_in_order`.
        if (pos.kind != VALUE) return INVALID_POSITION_KIND?;
        child = pos;
        pos = pos.prev_pos;
    }
    // Prev pos with the given kind hasn't been found.
    return INVALID_POSITION_KIND?;
}

fn void? UJsonCursor.end_list(&self)
{
    UJsonPosition* closest_list_pos = self.find_closest_pos(LIST, null)!;

    // CONSIDER: Should we check that all list items were used?

    usz arena_mark = closest_list_pos.arena_mark;
    self.pos = closest_list_pos.prev_pos;
    self.arena.reset(arena_mark);
}

macro void? UJsonCursor.@list(&self; @body())
{
    self.begin_list()!;

    @body();

    self.end_list()!;
}

fn bool? UJsonCursor.item(&self)
{
    // `closest_list_pos_child` contains `arena_mark` so we can free all descendants of `closest_list_pos`.
    UJsonPosition* closest_list_pos_child;
    UJsonPosition* closest_list_pos = self.find_closest_pos(LIST, &closest_list_pos_child)!;

    // Before moving to the next item in the list move cursor back to the list itself (if not already there).
    if (closest_list_pos_child)
    {
        self.pos = closest_list_pos;
        self.arena.reset(closest_list_pos_child.arena_mark);
    }

    UJsonList* list = closest_list_pos.value.ptr();
    // No more list items available.
    if (closest_list_pos.idx >= list.items.len) return false;

    // If allocation of child `UCursorPosition` fails
    // then we return to this mark to rollback all work except freeing descendants of `closest_list_pos`.
    // So in case of failure the cursor will stay at the list.
    usz mark = self.arena.mark();
    bool done;
    defer if (!done) self.arena.reset(mark);

    // Create child `UJsonPosition`.
    UJsonPosition* new_pos = allocator::new_try(self.arena, UJsonPosition)!;
    new_pos.arena_mark = mark;
    new_pos.prev_pos = closest_list_pos;
    new_pos.kind = VALUE;
    // Increment `closest_list_pos.idx` so the next time we get the next item.
    new_pos.value = list.items[closest_list_pos.idx++];

    self.pos = new_pos;

    done = true;
    return true;
}

fn int compare_strings(String a, String b) @local
{
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    return libc::memcmp(a.ptr, b.ptr, a.len);
}

fn int compare_ujson_strings(String data, UJsonString a, UJsonString b) @local
{
    if (a.range.len < b.range.len) return -1;
    if (a.range.len > b.range.len) return 1;
    return libc::memcmp(data.ptr + a.range.start, data.ptr + b.range.start, a.range.len);
}

fn void? UJsonCursor.begin_dict(&self)
{
    if (self.pos.kind != VALUE) return INVALID_POSITION_KIND?;
    if (self.pos.value.kind() != DICT) return INVALID_VALUE_KIND?;

    usz arena_mark = self.arena.mark();
    bool done;
    // Revert everything to the original state if something fails.
    defer if (!done) self.arena.reset(arena_mark);

    UJsonPosition* new_pos = allocator::new_try(self.arena, UJsonPosition)!;
    new_pos.arena_mark = arena_mark;
    new_pos.prev_pos = self.pos;
    new_pos.value = self.pos.value;  // Value hasn't changed yet.
    new_pos.kind = DICT;
    new_pos.remaining_fields.init_try(self.arena)!;
    new_pos.used_keys.init_try(self.arena)!;

    // Fill B-tree with the remaining items.
    UJsonDict* dict = self.pos.value.ptr();
    foreach (usz idx, UJsonString key : dict.keys)
    {
        BTreeSlot{UJsonField} slot = new_pos.remaining_fields.@get_slot_try(
            fn int(String data, UJsonString key, UJsonField field_from_tree) =>
                compare_ujson_strings(data, key, field_from_tree.key),
            self.data, key)!;

        // CONSIDER: Should we record the duplicate key somewhere? Or log it somewhere?
        if (slot.existed) return FIELDS_WITH_DUPLICATE_KEY?;

        *slot.item = { .key = key, .value = dict.values[idx] };
    }

    done = true;
    self.pos = new_pos;
}

fn void? UJsonCursor.end_dict(&self)
{
    UJsonPosition* closest_dict_pos = self.find_closest_pos(DICT, null)!;

    Maybe{UJsonField} field = closest_dict_pos.remaining_fields.first_item();
    if (field.has_value)
    {
        // CONSIDER: Should we record the key of the unused field somewhere? Or log it somewhere?
        return UNUSED_FIELD?;
    }

    usz arena_mark = closest_dict_pos.arena_mark;
    self.pos = closest_dict_pos.prev_pos;
    self.arena.reset(arena_mark);
}

macro void? UJsonCursor.@dict(&self; @body())
{
    self.begin_dict()!;

    @body();

    self.end_dict()!;
}

fn bool? UJsonCursor.field(&self, String key)
{
    // `closest_dict_pos_child` contains `arena_mark` so we can free all descendants of `closest_dict_pos`.
    UJsonPosition* closest_dict_pos_child;
    UJsonPosition* closest_dict_pos = self.find_closest_pos(DICT, &closest_dict_pos_child)!;

    // Before moving to another field in the dict move cursor back to the dict itself (if not already there).
    if (closest_dict_pos_child)
    {
        self.pos = closest_dict_pos;
        self.arena.reset(closest_dict_pos_child.arena_mark);
    }

    // Check that the key hasn't been already used.
    {
        BTreeSlot{String} slot = closest_dict_pos.used_keys.@get_existing_slot(
            fn int(String key, String used_key_from_tree) =>
                compare_strings(key, used_key_from_tree),
            key);
        if (slot.existed) return ALREADY_USED_KEY?;
    }

    // If allocation of `key_duplicate` fails or allocation of B-tree node fails
    // then we return to this mark to rollback all work except freeing descendants of `closest_dict_pos`.
    usz mark = self.arena.mark();
    bool done;
    defer if (!done) self.arena.reset(mark);

    // Make duplicate of `key`.
    String key_duplicate;
    {
        // We can't use `String.copy` because it panics when OOM.
        usz len = key.len;
        char* str = allocator::malloc_try(self.arena, len + 1)!;
        mem::copy(str, key.ptr, len);
        str[len] = 0;
        key_duplicate = (String)str[:len];
    }

    // Insert `key_duplicate` into B-tree.
    {
        BTreeSlot{String} slot = closest_dict_pos.used_keys.@get_slot_try(
            fn int(String key, String used_key_from_tree) =>
                compare_strings(key, used_key_from_tree),
            key)!;
        assert(!slot.existed);
        *slot.item = key_duplicate;
    }

    // If field with the given key exists then we have to allocate `UJsonPosition`.
    // If that allocation fails we can't unfortunately reset to the original `mark`
    // because even if we remove the newly inserted `key_duplicate` from B-tree
    // the structure of B-tree may not revert back to the original structure
    // and some pointers may still point to the newly added nodes.
    // So it would be wrong to free those nodes by resetting arena to `mark`.
    //
    // Instead we create a new mark and in case of failure we only remove `key_duplicate`
    // from B-tree with used keys so it is treated as unused. Unfortunately memory
    // for `key_duplicate` and B-tree nodes freed during removal won't be recovered until
    // the whole position `closest_dict_pos` is freed (ie. whole B-tree is freed).
    //
    // CONSIDER: Should we fix the above problem by allowing B-tree to preallocate nodes for insertion
    //           but do the actual insertion later? This would need change in B-tree API.
    //           Benefits of such fix are limited to a very special case.
    mark = self.arena.mark();
    defer if (!done)
    {
        bool removed = closest_dict_pos.used_keys.@remove(
            fn int(String key, String used_key_from_tree) =>
                compare_strings(key, used_key_from_tree),
            key_duplicate);
        assert(removed);
    }

    BTreeSlot{UJsonField} slot = closest_dict_pos.remaining_fields.@get_existing_slot(
        fn int(String data, String key, UJsonField field_from_tree) =>
            compare_strings(key, (String)data.ptr[field_from_tree.key.range.start:field_from_tree.key.range.len]),
        self.data, key_duplicate);

    if (!slot.existed)
    {
        done = true;
        return false;
    }

    // Create child `UJsonPosition`.
    UJsonPosition* new_pos = allocator::new_try(self.arena, UJsonPosition)!;
    new_pos.arena_mark = mark;
    new_pos.prev_pos = closest_dict_pos;
    new_pos.value = slot.item.value;
    new_pos.kind = VALUE;

    self.pos = new_pos;

    // Remove field from `remaining_fields`.
    // Removal is needed by `end_dict` which checks for no remaining fields.
    {
        bool removed = closest_dict_pos.remaining_fields.@remove(
            fn int(String data, UJsonString key, UJsonField field_from_tree) =>
                compare_ujson_strings(data, key, field_from_tree.key),
            self.data, slot.item.key);
        assert(removed);
    }

    done = true;
    return true;
}
