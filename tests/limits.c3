import std;
import ujson;

fn void test_parser_has_no_depth_limit() @test
{
    const usz HALF_DEPTH = 2_000_000;
    const usz NUM_OF_BYTES = 9 * HALF_DEPTH + 5 + 3 * HALF_DEPTH;

    DString ds;
    ds.init(mem, NUM_OF_BYTES);
    defer ds.free();

    for (int i = 0; i < HALF_DEPTH; i++)
    {
        ds.appendf("{ \"k%d\": [", i % 10);
    }
    ds.appendf("\"mid\"");
    for (int i = 0; i < HALF_DEPTH; i++)
    {
        ds.appendf("] }");
    }

    String input = ds.str_view();
    assert(input.len == NUM_OF_BYTES);

    @pool()
    {
        usz max_depth;
        usz parsed_bytes;
        Pos parsed_pos;
        UJsonValue root = ujson::parse_prefix_and_mutate_input(
            input,
            out_max_depth: &max_depth,
            out_parsed_bytes: &parsed_bytes,
            out_parsed_pos: &parsed_pos)!!;
        assert(max_depth == 2 * HALF_DEPTH);
        assert(parsed_bytes == NUM_OF_BYTES);
        assert(parsed_pos.line == 0);
        assert(parsed_pos.code_point == NUM_OF_BYTES);

        UJsonReader reader;
        reader.init(root, mem)!!;
        defer reader.free();

        UJsonCursor cur = reader.cursor();
        int i = 0;  // Useful when building `key` dynamically.
        while LOOP: (true)
        {
            switch (cur.value.kind())
            {
                case STRING:
                    assert(cur.str()!! == "mid");
                    break LOOP;
                case LIST:
                    UJsonListCursor list_cur = cur.list()!!;
                    cur = list_cur[0];
                case DICT:
                    UJsonDictCursor dict_cur = cur.dict()!!;
                    @stack_mem(128; Allocator allocator)
                    {
                        DString key;
                        key.init(allocator, 20);
                        key.appendf("k%d", i % 10);
                        cur = dict_cur.field(key.str_view())!!;
                    };
                    i += 1;
                default:
                    assert(false);
            }
        }
    };
}
