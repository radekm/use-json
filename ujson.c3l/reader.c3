module ujson;

import std;
import libc;
import btree;

enum UJsonValueKind : uint
{
    NULL,
    TRUE,
    FALSE,
    STRING,
    NUMBER,
    LIST,
    DICT,
}

// NOTE: We don't implement `UJsonValue.free` because it's complex to
//       implement it in O(n) time where `n` is the number of values without additional memory.
//       We would need to add `parent` and `index_in_parent` fields into `UJsonList` and `UJsonDict`.

struct UJsonValue
{
    // Low 3 bits encode kind.
    // This works because actual values have alignment at least 8.
    uptr ptr_with_kind;
}

struct UJsonString @align(8)
{
    String string;
}

struct UJsonNumber @align(8)
{
    String number;
}

struct UJsonList @align(8)
{
    UJsonValue[] items;
}

struct UJsonField
{
    String key;
    UJsonValue value;
}

struct UJsonDict @align(8)
{
    BTree{UJsonField} fields;
}

struct UJsonUsedField
{
    UJsonDict* dict;
    String key;
    bool key_copied;  // Means that `key` must be freed when freeing `UJsonReader`.
}

struct UJsonReader
{
    UJsonValue root;
    String last_error_file;
    String last_error_func;
    int last_error_line;
    BTree{UJsonUsedField} used_fields;
    Allocator allocator;
}

struct UJsonCursor
{
    UJsonReader* reader;
    UJsonValue value;
}

struct UJsonListCursor
{
    UJsonReader* reader;
    UJsonList* list;
}

struct UJsonDictCursor
{
    UJsonReader* reader;
    UJsonDict* dict;
}

fn UJsonValue make_value(void* ptr, UJsonValueKind kind)
{
    return { .ptr_with_kind = (uptr)ptr | (uptr)kind };
}

fn UJsonValueKind UJsonValue.kind(self)
{
    return (UJsonValueKind)(self.ptr_with_kind & 7);
}

fn void* UJsonValue.ptr(self)
{
    return (void*)(self.ptr_with_kind & ~(uptr)7);
}

faultdef
    INVALID_KIND,
    MISSING_FIELD,
    FIELD_ALREADY_USED;

fn bool UJsonCursor.not_null(self)
{
    return self.value.kind() != NULL;
}

fn bool? UJsonCursor.boolean(self, String file = $$FILE, String func = $$FUNC, int line = $$LINE)
{
    switch (self.value.kind())
    {
        case TRUE: return true;
        case FALSE: return false;
        default:
            self.reader.last_error_file = file;
            self.reader.last_error_func = func;
            self.reader.last_error_line = line;
            return INVALID_KIND?;
    }
}

fn String? UJsonCursor.str(&self, String file = $$FILE, String func = $$FUNC, int line = $$LINE)
{
    if (self.value.kind() != STRING)
    {
        self.reader.last_error_file = file;
        self.reader.last_error_func = func;
        self.reader.last_error_line = line;
        return INVALID_KIND?;
    }
    return ((UJsonString*)self.value.ptr()).string;
}

fn String? UJsonCursor.num_as_str(&self, String file = $$FILE, String func = $$FUNC, int line = $$LINE)
{
    if (self.value.kind() != NUMBER)
    {
        self.reader.last_error_file = file;
        self.reader.last_error_func = func;
        self.reader.last_error_line = line;
        return INVALID_KIND?;
    }
    return ((UJsonNumber*)self.value.ptr()).number;
}

fn long? UJsonCursor.num_as_long(self, String file = $$FILE, String func = $$FUNC, int line = $$LINE)
{
    String s = self.num_as_str(file, func, line)!;
    long? result = s.to_long();
    if (catch excuse = result)
    {
        self.reader.last_error_file = file;
        self.reader.last_error_func = func;
        self.reader.last_error_line = line;
        return excuse?;
    }
    return result;
}

fn double? UJsonCursor.num_as_double(self, String file = $$FILE, String func = $$FUNC, int line = $$LINE)
{
    String s = self.num_as_str(file, func, line)!;
    double? result = s.to_double();
    if (catch excuse = result)
    {
        self.reader.last_error_file = file;
        self.reader.last_error_func = func;
        self.reader.last_error_line = line;
        return excuse?;
    }
    return result;
}

fn UJsonListCursor? UJsonCursor.list(&self, String file = $$FILE, String func = $$FUNC, int line = $$LINE)
{
    if (self.value.kind() != LIST)
    {
        self.reader.last_error_file = file;
        self.reader.last_error_func = func;
        self.reader.last_error_line = line;
        return INVALID_KIND?;
    }
    UJsonList* list = self.value.ptr();
    return { .reader = self.reader, .list = list };
}

fn UJsonCursor UJsonListCursor.get(self, usz i) @operator([])
{
    return {
        .reader = self.reader,
        .value = self.list.items[i],
    };
}

fn usz UJsonListCursor.len(self) @operator(len)
{
    return self.list.items.len;
}

fn UJsonDictCursor? UJsonCursor.dict(&self, String file = $$FILE, String func = $$FUNC, int line = $$LINE)
{
    if (self.value.kind() != DICT)
    {
        self.reader.last_error_file = file;
        self.reader.last_error_func = func;
        self.reader.last_error_line = line;
        return INVALID_KIND?;
    }
    UJsonDict* dict = self.value.ptr();
    return { .reader = self.reader, .dict = dict };
}

fn int compare_keys(String a, String b)
{
    switch {
        case a.len < b.len: return -1;
        case a.len > b.len: return 1;
        default: return libc::memcmp(a.ptr, b.ptr, a.len);
    }
}

fn int compare_used_field(UJsonDict* dict, String key, UJsonUsedField item_from_tree)
{
    switch
    {
        case (uptr)dict < (uptr)item_from_tree.dict: return -1;
        case (uptr)dict > (uptr)item_from_tree.dict: return 1;
        default: return compare_keys(key, item_from_tree.key);
    }
}

fn bool? UJsonDictCursor.field_opt(
    &self, String key, UJsonCursor* out_cursor,
    String file = $$FILE, String func = $$FUNC, int line = $$LINE)
{
    BTreeSlot{UJsonUsedField} slot_among_used = self.reader.used_fields.@get_slot_try(
        compare_used_field,
        self.dict, key)!;
    if (slot_among_used.existed)
    {
        self.reader.last_error_file = file;
        self.reader.last_error_func = func;
        self.reader.last_error_line = line;
        return FIELD_ALREADY_USED?;
    }

    BTreeSlot{UJsonField} slot = self.dict.fields.@get_existing_slot(
        fn int(UJsonDict* dict, String key, UJsonField item_from_tree) => compare_keys(key, item_from_tree.key),
        self.dict, key);
    if (slot.existed)
    {
        slot_among_used.item.dict = self.dict;
        // We can't use `key` because its lifetime may not be long enough.
        // Instead we use the same key from JSON document `slot.item.key`.
        slot_among_used.item.key = slot.item.key;
        out_cursor.reader = self.reader;
        out_cursor.value = slot.item.value;
        return true;
    }
    else
    {
        slot_among_used.item.dict = self.dict;
        // Zero length is a special case because we don't want to call `malloc_try` with zero size.
        if (key == "")
        {
            slot_among_used.item.key = "";
        }
        else
        {
            // We can't use `key` because its lifetime may not be long enough.
            // We have to make a copy with long enough lifetime.
            // Unfortunately we can't use `key.copy(self.reader.allocator)` because that would panic if OOM.
            usz len = key.len;
            char*? key_dup = allocator::malloc_try(self.reader.allocator, len);
            if (catch excuse = key_dup)
            {
                // We were unable to duplicate `key`.
                // Let's rollback and remove `slot_among_used.item` which was inserted at the beginning of `field_opt`.
                slot_among_used.item.key = key;  // Set `key` so we can remove the item from the tree.
                self.reader.used_fields.@remove(
                    compare_used_field,
                    self.dict, key);
                return excuse?;
            }
            mem::copy(key_dup, key.ptr, len);
            slot_among_used.item.key = (String)key_dup[:len];
            slot_among_used.item.key_copied = true;
        }
        return false;
    }
}

fn UJsonCursor? UJsonDictCursor.field(
    &self, String key,
    String file = $$FILE, String func = $$FUNC, int line = $$LINE)
{
    UJsonCursor result;
    if (self.field_opt(key, &result, file, func, line)!) return result;

    self.reader.last_error_file = file;
    self.reader.last_error_func = func;
    self.reader.last_error_line = line;
    return MISSING_FIELD?;
}

// May fail with OOM.
fn void? UJsonReader.init(&self, UJsonValue root, Allocator allocator)
{
    *self = {};
    // Let's start with `init_try` which can fail. So in case of failure `self` is zero.
    self.used_fields.init_try(allocator)!;
    self.root = root;
    self.allocator = allocator;
}

fn UJsonCursor UJsonReader.cursor(&self)
{
    return {
        .reader = self,
        .value = self.root,
    };
}

fn void UJsonReader.free(&self)
{
    // Free copied keys.
    self.used_fields.@each(; UJsonUsedField* item_from_tree)
    {
        if (item_from_tree.key_copied)
        {
            item_from_tree.key.free(self.allocator);
        }
    };
    self.used_fields.free();
    *self = {};
}
