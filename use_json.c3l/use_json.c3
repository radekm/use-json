module use_json;

import std;
import libc;
import btree;

enum UJsonValueKind : uint
{
    NULL,
    FALSE,
    TRUE,
    STRING,
    NUMBER,
    LIST,
    DICT,
}

struct UJsonValue
{
    // Low 3 bits encode kind.
    // This works because actual values have alignment at least 8.
    uptr ptr_with_kind;
}

// Range of strings and numbers in a buffer with input data.
struct UJsonRange
{
    uint start;
    uint len;
}

struct UJsonString @align(8)
{
    UJsonRange range;
}

struct UJsonNumber @align(8)
{
    UJsonRange range;
}

struct UJsonList @align(8)
{
    UJsonValue[] items;
}

struct UJsonDict @align(8)
{
    UJsonString[] keys;
    UJsonValue[] values;
}

// CONSIDER: Should this contain max depth?
struct UJsonParsed
{
    String data;
    UJsonValue root;
}

struct UJsonField
{
    UJsonString key;
    UJsonValue value;
}

enum UJsonPositionKind : uint
{
    VALUE,
    LIST,
    DICT,
    DICT_IN_ORDER,
}

struct UJsonPosition
{
    // State of arena before creating this position.
    // Resetting arena to this mark will free this position.
    usz arena_mark;
    UJsonPosition* prev_pos;
    UJsonValue value;
    UJsonPositionKind kind;

    // `idx` is used only when `kind` is `LIST` or `DICT_IN_ORDER`.
    // Otherwise it should be zero.
    uint idx;

    // B-trees are used only when `kind` is `DICT`.
    // Otherwise they should be zero.
    //
    // If a key is used the field with that key is removed from `remaining_fields`.
    BTree{UJsonField} remaining_fields;
    BTree{String} used_keys;
}

struct UJsonCursor
{
    ArenaAllocator* arena;
    String data;
    UJsonPosition* pos;  // Never `null` when the cursor is valid.
}
