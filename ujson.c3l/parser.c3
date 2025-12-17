module ujson;

import std;
import btree;

// - We allow optional comma after the last item in lists and dicts.
// - We allow single-line comments starting with `//` which end at the end of line or with the end of data.
// - Duplicate keys in dicts are not allowed.
//   Keys are considered duplicate if after decoding of escape sequences they produce same bytes.
// - Strings must be valid UTF-8.
// - Parser is not recursive and supports unlimited depth
//   (the only limit is memory provided by allocators).
// - Parser supports unlimited precision of numbers
//   (reader can return numbers as strings).


// Initial `Pos` is zero.
// `line` is incremented after `\r\n` or `\r` or `\n`.
// `code_point` is incremented after each code point on the line and zeroed with a new line.
//
// `code_point` is an approximation of column but column should depend on graphemes.
struct Pos
{
    usz line;
    usz code_point;
}

faultdef
    INVALID_UTF8,
    INVALID_COMMENT,
    INVALID_STRING,
    INVALID_ESCAPE_SEQUENCE,
    INVALID_NUMBER,
    INVALID_TOKEN,
    UNEXPECTED_END_OF_INPUT,
    DUPLICATE_KEY,
    UNEXPECTED_TRAILING_INPUT;

struct PartialList @private
{
    // We can't use `List{UJsonValue}` because it panics in case of OOM.
    // Allocated with `work_arena` because dynamic list is not arena friendly.
    SList{UJsonValue} items;
}

struct PartialDict @private
{
    String last_key;
    // Allocated directly with `result_arena` because `BTree` is arena friendly.
    BTree{UJsonField} fields;
}

enum PartialKind @private { LIST, DICT }

struct Partial @private
{
    PartialKind kind;
    union
    {
        PartialList list;
        PartialDict dict;
    }
}

// Used to validate and read both single-byte and multi-byte code points inside comments and strings.
// `n` is the number of bytes read.
fn bool read_code_point(char[] input, usz at, Char32* out_code_point, usz* out_n) @private
{
    if (at >= input.len) return false;
    char b = input[at];

    switch
    {
        case b < 0x80:
            *out_code_point = b;
            *out_n = 1;
            return true;
        case (b & 0b1110_0000) == 0b1100_0000:
            if (at + 1 >= input.len) return false;
            char b2 = input[at + 1];
            if ((b2 & 0xC0) != 0x80) return false;

            Char32 cp = (uint)(b & 0x1F) << 6 | (uint)(b2 & 0x3F);
            if (cp < 0x80) return false;  // Overlong.
            *out_code_point = cp;
            *out_n = 2;
            return true;
        case (b & 0b1111_0000) == 0b1110_0000:
            if (at + 2 >= input.len) return false;
            char b2 = input[at + 1];
            char b3 = input[at + 2];
            if ((b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80) return false;

            Char32 cp = (uint)(b & 0x0F) << 12 | (uint)(b2 & 0x3F) << 6 | (uint)(b3 & 0x3F);
            if (cp < 0x800) return false;  // Overlong.
            if (cp >= 0xD800 && cp <= 0xDFFF) return false;  // Surrogates are not legal Unicode values.
            *out_code_point = cp;
            *out_n = 3;
            return true;
        case (b & 0b1111_1000) == 0b1111_0000:
            if (at + 3 >= input.len) return false;
            char b2 = input[at + 1];
            char b3 = input[at + 2];
            char b4 = input[at + 3];
            if ((b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80 || (b4 & 0xC0) != 0x80) return false;

            Char32 cp = (uint)(b & 0x07) << 18 | (uint)(b2 & 0x3F) << 12 | (uint)(b3 & 0x3F) << 6 | (uint)(b4 & 0x3F);
            if (cp < 0x10000) return false;  // Overlong.
            if (cp > 0x10FFFF) return false;  // Too big code point.
            *out_code_point = cp;
            *out_n = 4;
            return true;
        default:
            return false;
    }
}

// Assumes that `code_point` is valid (ie. not too big and not surrogate).
// This assumption is fine because we only write code points which we read and validated before.
//
// Another assumption is that there's enough space in a buffer.
// This should also be the case because we use this function to replace one or two unicode escape sequences
// which have 6 or 12 bytes.
fn usz write_code_point(char[] output, usz at, Char32 code_point) @private
{
    switch
    {
        case code_point < 0x80:  // 7 bits.
            output[at] = (char)code_point;
            return 1;
        case code_point < 0x800:  // 11 bits.
            output[at]     = (char)(code_point >> 6)   | 0xC0;
            output[at + 1] = (char)(code_point & 0x3F) | 0x80;
            return 2;
        case code_point < 0x10000:  // 16 bits.
            output[at]     = (char)(code_point >> 12)         | 0xE0;
            output[at + 1] = (char)((code_point >> 6) & 0x3F) | 0x80;
            output[at + 2] = (char)(code_point & 0x3F)        | 0x80;
            return 3;
        default:  // 21 bits.
            // 4 bytes (we assume that code point is not too big).
            output[at]     = (char)(code_point >> 18)          | 0xF0;
            output[at + 1] = (char)((code_point >> 12) & 0x3F) | 0x80;
            output[at + 2] = (char)((code_point >> 6) & 0x3F)  | 0x80;
            output[at + 3] = (char)(code_point & 0x3F)         | 0x80;
            return 4;
    }
}

fn uint? parse_4_hex_digits(char[] input, usz at) @private
{
    if (at + 3 >= input.len) return INVALID_ESCAPE_SEQUENCE?;

    uint n;
    for (int i = 0; i < 4; i++)
    {
        n *= 16;
        char d = input[at + i];
        switch (d)
        {
            case '0' .. '9': n += (uint)(d - '0');
            case 'a' .. 'f': n += (uint)(d - 'a' + 10);
            case 'A' .. 'F': n += (uint)(d - 'A' + 10);
            default:
                return INVALID_ESCAPE_SEQUENCE?;
        }
    }
    return n;
}

// Assumes that opening double quote has already been consumed
// and `input[parsed_bytes]` points to the first code point of the string.
// This function consumes closing double quote.
//
// Escape sequences are replaced by the code points they represent.
// So the `input` is mutated in place.
fn String? parse_string_and_mutate_input(
    char[] input, usz parsed_bytes, Pos parsed_pos,
    usz* out_parsed_bytes, Pos* out_parsed_pos) @private
{
    usz initially_parsed_bytes = parsed_bytes;
    usz write_at = parsed_bytes;
    // Ensure that the current position is returned.
    defer {
        *out_parsed_bytes = parsed_bytes;
        *out_parsed_pos = parsed_pos;
    }

    while (parsed_bytes < input.len)
    {
        Char32 cp;
        usz n;
        // Multi-byte code points can appear inside string, so we use `read_code_point`.
        if (!read_code_point(input, parsed_bytes, &cp, &n)) return INVALID_UTF8?;

        switch (cp)
        {
            case '"':
                parsed_bytes += n;
                parsed_pos.code_point += 1;
                return (String)input[initially_parsed_bytes .. write_at - 1];
            case '\\':
                assert(n == 1);

                if (parsed_bytes + 1 >= input.len) return INVALID_ESCAPE_SEQUENCE?;

                char b = input[parsed_bytes + 1];
                switch (b)
                {
                    case '"':
                    case '\\':
                    case '/':
                    case 'b':
                    case 'f':
                    case 'n':
                    case 'r':
                    case 't':
                        parsed_bytes += 2;
                        parsed_pos.code_point += 2;
                        switch (b)
                        {
                            case 'b': b = '\b';
                            case 'f': b = '\f';
                            case 'n': b = '\n';
                            case 'r': b = '\r';
                            case 't': b = '\t';
                        }
                        input[write_at++] = b;
                    case 'u':
                        uint hex_code = parse_4_hex_digits(input, parsed_bytes + 2)!;

                        // Surrogate range.
                        if (hex_code >= 0xD800 && hex_code <= 0xDFFF)
                        {
                            // Low surrogate before preceding high surrogate.
                            if (hex_code > 0xDBFF) return INVALID_ESCAPE_SEQUENCE?;
                            parsed_bytes += 6;
                            parsed_pos.code_point += 6;

                            // We have high surrogate and we must read low surrogate.
                            if (parsed_bytes + 5 >= input.len) return INVALID_ESCAPE_SEQUENCE?;
                            if (input[parsed_bytes] != '\\' || input[parsed_bytes + 1] != 'u')
                            {
                                return INVALID_ESCAPE_SEQUENCE?;
                            }
                            uint hex_code_low_sur = parse_4_hex_digits(input, parsed_bytes + 2)!;

                            // `hex_code_low_sur` must contain low surrogate.
                            if (hex_code_low_sur < 0xDC00 || hex_code_low_sur > 0xDFFF)
                            {
                                return INVALID_ESCAPE_SEQUENCE?;
                            }
                            parsed_bytes += 6;
                            parsed_pos.code_point += 6;

                            cp = ((hex_code & 0x3FF) << 10 | (hex_code_low_sur & 0x3FF)) + 0x10000;
                        }
                        else
                        {
                            // No surrogate pair.
                            parsed_bytes += 6;
                            parsed_pos.code_point += 6;

                            cp = hex_code;
                        }

                        // Write code point in UTF-8 encoding.
                        n = write_code_point(input, write_at, cp);
                        write_at += n;
                    default:
                        return INVALID_ESCAPE_SEQUENCE?;
                }
            default:
                if (cp < 32) return INVALID_STRING?;
                mem::move(input[write_at ..].ptr, input[parsed_bytes ..].ptr, n);
                parsed_bytes += n;
                parsed_pos.code_point += 1;
                write_at += n;
        }
    }

    return UNEXPECTED_END_OF_INPUT?;
}

fn usz skip_digits(char[] input, usz at) @private
{
    usz n;
    while (at + n < input.len)
    {
        switch (input[at + n])
        {
            case '0' .. '9': n++;
            default:
                return n;
        }
    }
    return n;
}

// Assumes that initial digit or minus sign wasn't consumed
// and `input[cur_parsed_bytes]` points to this digit or minus sign.
//
// Parsing is greedy, it tries to consume as much bytes as possible.
fn String? parse_number(
    char[] input, usz parsed_bytes, Pos parsed_pos,
    usz* out_parsed_bytes, Pos* out_parsed_pos) @private
{
    usz initially_parsed_bytes = parsed_bytes;
    // Ensure that the current position is returned.
    defer {
        *out_parsed_bytes = parsed_bytes;
        *out_parsed_pos = parsed_pos;
    }

    // Skip optional `-` at the beginning.
    if (input[parsed_bytes] == '-')
    {
        parsed_bytes++;
        parsed_pos.code_point++;
    }

    // Skip digits after sign.
    if (parsed_bytes >= input.len) return UNEXPECTED_END_OF_INPUT?;
    {
        usz n = skip_digits(input, parsed_bytes);
        switch
        {
            // No digits.
            case n == 0:
                return INVALID_NUMBER?;
            // Zero must not be followed by other digits.
            case n > 1 && input[parsed_bytes] == '0':
                // Move after initial zero.
                parsed_bytes++;
                parsed_pos.code_point++;
                return INVALID_NUMBER?;
        }

        parsed_bytes += n;
        parsed_pos.code_point += n;
    }

    // Skip optional fraction.
    if (parsed_bytes < input.len && input[parsed_bytes] == '.')
    {
        parsed_bytes++;
        parsed_pos.code_point++;

        usz n = skip_digits(input, parsed_bytes);
        parsed_bytes += n;
        parsed_pos.code_point += n;

        // Fraction must contain at least one digit.
        if (n == 0)
        {
            if (parsed_bytes >= input.len) return UNEXPECTED_END_OF_INPUT?;
            return INVALID_NUMBER?;
        }
    }

    // Skip optional exponent.
    if (parsed_bytes < input.len)
    {
        char b = input[parsed_bytes];
        if (b == 'e' || b == 'E')
        {
            parsed_bytes++;
            parsed_pos.code_point++;

            if (parsed_bytes >= input.len) return UNEXPECTED_END_OF_INPUT?;

            // Skip optional sign.
            b = input[parsed_bytes];
            if (b == '+' || b == '-')
            {
                parsed_bytes++;
                parsed_pos.code_point++;
            }

            usz n = skip_digits(input, parsed_bytes);
            parsed_bytes += n;
            parsed_pos.code_point += n;

            // Exponent must contain at least one digit.
            if (n == 0)
            {
                if (parsed_bytes >= input.len) return UNEXPECTED_END_OF_INPUT?;
                return INVALID_NUMBER?;
            }
        }
    }

    return (String)input[initially_parsed_bytes .. parsed_bytes - 1];
}

// When this function returns without error we're at the end of input
// or before a non-comment and a non-whitespace code point.
fn void? skip_comments_and_whitespace(
    char[] input, usz parsed_bytes, Pos parsed_pos,
    usz* out_parsed_bytes, Pos* out_parsed_pos) @private
{
    usz initially_parsed_bytes = parsed_bytes;
    // Ensure that the current position is returned.
    defer {
        *out_parsed_bytes = parsed_bytes;
        *out_parsed_pos = parsed_pos;
    }

    while (parsed_bytes < input.len)
    {
        char b = input[parsed_bytes];
        switch (b)
        {
            case ' ':
            case '\t':
                parsed_bytes++;
                parsed_pos.code_point++;
            case '\n':
            case '\r':
                parsed_bytes++;
                parsed_pos.line++;
                parsed_pos.code_point = 0;

                // Check if the line ending isn't `\r\n`.
                if (b == '\r' && parsed_bytes < input.len && input[parsed_bytes] == '\n') parsed_bytes++;
            case '/':
                if (parsed_bytes + 1 >= input.len || input[parsed_bytes + 1] != '/') return INVALID_COMMENT?;
                parsed_bytes += 2;
                parsed_pos.code_point += 2;

                // Skip code points until end of line or end of input.
                while (parsed_bytes < input.len)
                {
                    // Multi-byte code points can appear only inside comments.
                    // So we use `read_code_point` only inside comments.
                    Char32 cp;
                    usz n;
                    if (!read_code_point(input, parsed_bytes, &cp, &n)) return INVALID_UTF8?;

                    // End of line is processed by outer loop.
                    if (cp == '\n' || cp == '\r') break;

                    if (cp < 32 && cp != '\t') return INVALID_COMMENT?;

                    parsed_bytes += n;
                    parsed_pos.code_point += 1;
                }
            default:
                return;
        }
    }
}

enum State @private
{
    AFTER_LIST_OPENING, AFTER_LIST_ITEM, AFTER_LIST_COMMA,
    AFTER_DICT_OPENING, AFTER_DICT_KEY, AFTER_DICT_COLON, AFTER_DICT_VALUE, AFTER_DICT_COMMA,
}

// Parses JSON from `input` buffer. `input` buffer may be mutated (even if this function fails).
// Parsed `String` and `Number` values will point directly into `input` buffer.
//
// Parsed values are allocated with `result_arena` allocator.
// These values are not freed even if `parse_prefix_and_mutate_input` fails.
//
// On the other hand, temporary structures used for parsing are allocated with `work_allocator`
// and these are always freed. Since these temporary structures may grow and shrink,
// allocators which don't support reallocation are not a good fit for them.
fn UJsonValue? parse_prefix_and_mutate_input(
    char[] input, usz parsed_bytes = 0, Pos parsed_pos = {},
    usz* out_max_depth = null, usz* out_parsed_bytes = null, Pos* out_parsed_pos = null,
    Allocator result_arena = tmem, Allocator work_allocator = mem)
{
    usz max_depth;
    // Ensure that the current max_depth and position are returned.
    defer {
        if (out_max_depth) *out_max_depth = max_depth;
        if (out_parsed_bytes) *out_parsed_bytes = parsed_bytes;
        if (out_parsed_pos) *out_parsed_pos = parsed_pos;
    }

    SList{Partial} partial;
    defer {
        // We intentionally don't free values allocated with `result_arena`.
        // It would be too difficult because they can be arbitrary deep and we don't want to use any extra memory.
        foreach (&p : partial)
        {
            switch (p.kind)
            {
                case LIST:
                    p.list.items.free(work_allocator);
                case DICT:
                    // No need to free because BTrees were allocated with `result_arena`.
            }
        }
        partial.free(work_allocator);
    }

    State state;

    // Each iteration processes one token optionally preceded by comments and whitespace.
    // The loop ends with an error or when the value is parsed.
    while NEXT_TOKEN: (true)
    {
        skip_comments_and_whitespace(input, parsed_bytes, parsed_pos, &parsed_bytes, &parsed_pos)!;

        if (parsed_bytes >= input.len) return UNEXPECTED_END_OF_INPUT?;

        // Multi-byte code points can appear only in comments and strings.
        // So at this point we don't have to use `read_code_point`.
        char b = input[parsed_bytes];

        Maybe{UJsonValue} value;

        // Process tokens which may appear only inside list or dict.
        if (partial.len() != 0)
        {
            switch BYTE_SWITCH: (b)
            {
                case ']':
                    switch (state)
                    {
                        // End of list may appear in any list state.
                        case AFTER_LIST_OPENING:
                        case AFTER_LIST_ITEM:
                        case AFTER_LIST_COMMA:
                            parsed_bytes++;
                            parsed_pos.code_point++;

                            Partial p = partial.pop();
                            assert(p.kind == LIST);
                            defer p.list.items.free(work_allocator);

                            // Create list value.
                            UJsonList* list_value = allocator::new_try(result_arena, UJsonList)!;

                            // Copy items from `work_allocator` to `result_arena`.
                            if (p.list.items.len() != 0)
                            {
                                list_value.items = allocator::alloc_array_try(result_arena, UJsonValue, p.list.items.len())!;
                                mem::copy(list_value.items.ptr, p.list.items.data, p.list.items.len() * UJsonValue.sizeof);
                            }
                            value.set(make_value(list_value, LIST));
                            // New `state` is set when processing new `value`.
                        default:
                            return INVALID_TOKEN?;
                    }
                case '}':
                    switch (state)
                    {
                        case AFTER_DICT_OPENING:
                        case AFTER_DICT_VALUE:
                        case AFTER_DICT_COMMA:
                            parsed_bytes++;
                            parsed_pos.code_point++;

                            Partial p = partial.pop();
                            assert(p.kind == DICT);

                            // Create dict value. And make shallow copy of `BTree` which works
                            // because it was already allocated with `result_arena`.
                            UJsonDict* dict_value = allocator::new_try(result_arena, UJsonDict)!;
                            dict_value.fields = p.dict.fields;
                            value.set(make_value(dict_value, DICT));
                            // New `state` is set when processing new `value`.
                        default:
                            return INVALID_TOKEN?;
                    }
                case ':':
                    switch (state)
                    {
                        case AFTER_DICT_KEY:
                            parsed_bytes++;
                            parsed_pos.code_point++;
                            state = AFTER_DICT_COLON;
                            continue NEXT_TOKEN;
                        default:
                            return INVALID_TOKEN?;
                    }
                case ',':
                    switch (state)
                    {
                        case AFTER_LIST_ITEM:
                            parsed_bytes++;
                            parsed_pos.code_point++;
                            state = AFTER_LIST_COMMA;
                            continue NEXT_TOKEN;
                        case AFTER_DICT_VALUE:
                            parsed_bytes++;
                            parsed_pos.code_point++;
                            state = AFTER_DICT_COMMA;
                            continue NEXT_TOKEN;
                        default:
                            return INVALID_TOKEN?;
                    }
                default:
                    switch (state)
                    {
                        case AFTER_LIST_OPENING:
                        case AFTER_LIST_COMMA:
                        case AFTER_DICT_COLON:
                            // We expect start of new value.
                            // Let the execution continue below.
                            break BYTE_SWITCH;
                        case AFTER_DICT_OPENING:
                        case AFTER_DICT_COMMA:
                            // We expect key (because we already know that there isn't `}`).
                            if (b != '"') return INVALID_TOKEN?;

                            parsed_bytes++;
                            parsed_pos.code_point++;

                            String key = parse_string_and_mutate_input(
                                input, parsed_bytes, parsed_pos,
                                &parsed_bytes, &parsed_pos)!;

                            Partial* p = &partial[partial.len() - 1];
                            assert(p.kind == DICT);
                            p.dict.last_key = key;
                            state = AFTER_DICT_KEY;
                            continue NEXT_TOKEN;
                        default:
                            // We read byte which was not expected in current state.
                            return INVALID_TOKEN?;
                    }
            }
        }

        // No `value` at this point means that `b` wasn't processed yet
        // and start of a new value is expected.
        if (!value.has_value)
        {
            switch (b)
            {
                case 'n':
                    bool ok = parsed_bytes + 3 < input.len;
                    ok = ok && input[parsed_bytes + 1] == 'u';
                    ok = ok && input[parsed_bytes + 2] == 'l';
                    ok = ok && input[parsed_bytes + 3] == 'l';
                    if (!ok) return INVALID_TOKEN?;
                    parsed_bytes += 4;
                    parsed_pos.code_point += 4;
                    value.set(make_value(null, NULL));
                case 't':
                    bool ok = parsed_bytes + 3 < input.len;
                    ok = ok && input[parsed_bytes + 1] == 'r';
                    ok = ok && input[parsed_bytes + 2] == 'u';
                    ok = ok && input[parsed_bytes + 3] == 'e';
                    if (!ok) return INVALID_TOKEN?;
                    parsed_bytes += 4;
                    parsed_pos.code_point += 4;
                    value.set(make_value(null, TRUE));
                case 'f':
                    bool ok = parsed_bytes + 4 < input.len;
                    ok = ok && input[parsed_bytes + 1] == 'a';
                    ok = ok && input[parsed_bytes + 2] == 'l';
                    ok = ok && input[parsed_bytes + 3] == 's';
                    ok = ok && input[parsed_bytes + 4] == 'e';
                    if (!ok) return INVALID_TOKEN?;
                    parsed_bytes += 5;
                    parsed_pos.code_point += 5;
                    value.set(make_value(null, FALSE));
                case '"':
                    parsed_bytes++;
                    parsed_pos.code_point++;

                    String str = parse_string_and_mutate_input(
                        input, parsed_bytes, parsed_pos,
                        &parsed_bytes, &parsed_pos)!;

                    UJsonString* str_value = allocator::new_try(result_arena, UJsonString)!;
                    str_value.string = str;
                    value.set(make_value(str_value, STRING));
                // Numbers can't start with `+`.
                case '-':
                case '0' .. '9':
                    String num = parse_number(
                        input, parsed_bytes, parsed_pos,
                        &parsed_bytes, &parsed_pos)!;

                    UJsonNumber* num_value = allocator::new_try(result_arena, UJsonNumber)!;
                    num_value.number = num;
                    value.set(make_value(num_value, NUMBER));
                case '[':
                    parsed_bytes++;
                    parsed_pos.code_point++;

                    Partial p;
                    p.kind = LIST;
                    partial.push(p, work_allocator)!;
                    max_depth = max(max_depth, partial.len());  // Update `max_depth`.

                    state = AFTER_LIST_OPENING;
                case '{':
                    parsed_bytes++;
                    parsed_pos.code_point++;

                    Partial p;
                    p.kind = DICT;
                    p.dict.fields.init_try(result_arena)!;
                    partial.push(p, work_allocator)!;
                    max_depth = max(max_depth, partial.len());  // Update `max_depth`.

                    state = AFTER_DICT_OPENING;
                default:
                    return INVALID_TOKEN?;
            }
        }

        // We have read value.
        // If we don't exit the function we must set new `state`.
        if (value.has_value)
        {
            UJsonValue v = value.value;
            // Top-level value has been read. We're done.
            if (partial.len() == 0) return v;

            // Othwerwise we're inside list or dict and we read one item.
            Partial* p = &partial[partial.len() - 1];
            switch (p.kind)
            {
                case LIST:
                    state = AFTER_LIST_ITEM;
                    p.list.items.push(v, work_allocator)!;
                case DICT:
                    state = AFTER_DICT_VALUE;
                    BTreeSlot{UJsonField} slot = p.dict.fields.@get_slot_try(
                        fn int(String key, UJsonField item_from_tree) => compare_keys(key, item_from_tree.key),
                        p.dict.last_key)!;
                    // CONSIDER: Record which key is duplicate.
                    if (slot.existed) return DUPLICATE_KEY?;
                    *slot.item = { .key = p.dict.last_key, .value = v };
            }
        }
    }
}
