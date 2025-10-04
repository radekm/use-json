import std;
import use_json;

fn void test_cursor_without_parser() @test
{
    // Note that JSON string `Quote \"` is modified by parser into `Quote ""`.
    String data = `{"list": [true, null, 1, "Quote """], "empty dict": {}}`;
    @pool()
    {
        UJsonNumber* number = mem::tnew(UJsonNumber, { .range = { .start = 22, .len = 1 } });
        UJsonString* string_with_quote = mem::tnew(UJsonString, { .range = { .start = 26, .len = 7 } });
        UJsonList* list = mem::tnew(UJsonList);
        list.items = mem::temp_array(UJsonValue, 4);
        list.items[0] = use_json::make_value(null, UJsonValueKind.TRUE);
        list.items[1] = use_json::make_value(null, UJsonValueKind.NULL);  // Not necessary because this value is zero.
        list.items[2] = use_json::make_value(number, UJsonValueKind.NUMBER);
        list.items[3] = use_json::make_value(string_with_quote, UJsonValueKind.STRING);
        UJsonDict* empty_dict = mem::tnew(UJsonDict);

        UJsonDict* top_level_dict = mem::tnew(UJsonDict);
        top_level_dict.fields = mem::temp_array(UJsonField, 2);
        top_level_dict.fields[0] = {
            // Key `list`.
            .key = { .range = { .start = 2, .len = 4 } },
            .value = use_json::make_value(list, UJsonValueKind.LIST),
        };
        top_level_dict.fields[1] = {
            // Key `empty dict`.
            .key = { .range = { .start = 39, .len = 10 } },
            .value = use_json::make_value(empty_dict, UJsonValueKind.DICT),
        };

        UJsonParsed parsed = {
            .data = data,
            .root = use_json::make_value(top_level_dict, UJsonValueKind.DICT),
        };

        char[] arena_buffer = mem::talloc_array(char, 8 * mem::MB);
        ArenaAllocator* arena = allocator::wrap(arena_buffer);

        UJsonCursor c = parsed.to_cursor(arena);
        c.@dict()
        {
            assert(!c.field("unknown field")!!);
            assert(c.field("list")!!);
            c.@list()
            {
                assert(c.item()!!);
                assert(c.get_bool()!!);

                assert(c.item()!!);
                assert(!c.non_null()!!);

                assert(c.item()!!);
                assert(c.get_number_as_string()!! == "1");

                assert(c.item()!!);
                assert(c.get_string()!! == "Quote \"");

                // Items which don't exist.
                assert(!c.item()!!);
                assert(!c.item()!!);
            }!!;
            assert(c.field("empty dict")!!);
            c.@dict()
            {
            }!!;
        }!!;
    };
}
