import std;
import btree;
import ujson;

fn void test_cursor_without_parser() @test
{
    // Note that JSON string `Quote \"` is modified by parser into `Quote ""`.
    String data = `{"list": [true, null, 1, "Quote """], "empty dict": {}}`;
    @pool()
    {
        UJsonNumber* number = mem::tnew(UJsonNumber, { .number = data[22 : 1] });
        UJsonString* string_with_quote = mem::tnew(UJsonString, { .string = data[26 : 7] });
        UJsonList* list = mem::tnew(UJsonList);
        list.items = mem::temp_array(UJsonValue, 4);
        list.items[0] = ujson::make_value(null, TRUE);
        list.items[1] = ujson::make_value(null, NULL);  // Not necessary because this value is zero.
        list.items[2] = ujson::make_value(number, NUMBER);
        list.items[3] = ujson::make_value(string_with_quote, STRING);
        UJsonDict* empty_dict = mem::tnew(UJsonDict);
        empty_dict.fields.init(tmem);

        UJsonDict* top_level_dict = mem::tnew(UJsonDict);
        top_level_dict.fields.init(tmem);
        {
            // Key `list`.
            String key = data[2 : 4];
            BTreeSlot{UJsonField} slot = top_level_dict.fields.@get_slot(
                fn int(String key, UJsonField item_from_tree) => ujson::compare_keys(key, item_from_tree.key),
                key);
            slot.item.key = key;
            slot.item.value = ujson::make_value(list, LIST);
        }
        {
            // Key `empty dict`.
            String key = data[39 : 10];
            BTreeSlot{UJsonField} slot = top_level_dict.fields.@get_slot(
                fn int(String key, UJsonField item_from_tree) => ujson::compare_keys(key, item_from_tree.key),
                key);
            slot.item.key = key;
            slot.item.value = ujson::make_value(empty_dict, DICT);
        }

        UJsonReader reader;
        reader.init(ujson::make_value(top_level_dict, DICT), mem)!!;
        defer reader.free();

        UJsonDictCursor dict_cur = reader.cursor().dict()!!;
        {
            UJsonCursor cur;
            assert(!dict_cur.field_opt("unknown field", &cur)!!);
        }

        usz last_idx;
        foreach (idx, cur : dict_cur.field("list")!!.list()!!)
        {
            switch (idx)
            {
                case 0: assert(cur.boolean()!!);
                case 1: assert(!cur.not_null());
                case 2: assert(cur.num_as_long()!! == 1);
                case 3: assert(cur.str()!! == "Quote \"");
                default: assert(false);
            }
            last_idx = idx;
        }
        assert(last_idx == 3);

        {
            UJsonCursor cur;
            assert(dict_cur.field_opt("empty dict", &cur)!!);
        }
    };
}

fn void test_error_location_reporting() @test
{
    @pool()
    {
        UJsonValue root = ujson::make_value(null, FALSE);
        UJsonReader reader;
        reader.init(root, mem)!!;
        defer reader.free();
        UJsonCursor cur = reader.cursor();

        int line_before = $$LINE;
        fault excuse = @catch(cur.dict());
        assert(excuse == ujson::INVALID_KIND);
        assert(reader.last_error_file == $$FILE);
        assert(reader.last_error_func == $$FUNC);
        assert(reader.last_error_line == line_before + 1);
    };
}

fn void test_parsing_and_reading() @test
{
    @pool()
    {
        String s = `{ "str": "Hello", "num": 123, "list": [0.12, true, null, false, ] }`;
        String input = s.tcopy();

        UJsonValue root = ujson::parse_prefix_and_mutate_input(input)!!;
        UJsonReader reader;
        // Test reading.
        reader.init(root, mem)!!;
        defer reader.free();

        UJsonCursor cur = reader.cursor();
        UJsonDictCursor dict_cur = cur.dict()!!;
        assert(dict_cur.field("str")!!.str()!! == "Hello");;
        assert(dict_cur.field("num")!!.num_as_str()!! == "123");

        UJsonListCursor list_cur = dict_cur.field("list")!!.list()!!;
        foreach (idx, item_cur : list_cur)
        {
            switch (idx)
            {
                case 0:
                    assert(item_cur.num_as_double()!! == 0.12);
                case 1:
                    assert(item_cur.boolean()!! == true);
                case 2:
                    assert(item_cur.not_null() == false);
                case 3:
                    assert(item_cur.boolean()!! == false);
                default:
                    assert(false);
            }
        }
        assert(list_cur.len() == 4);

        UJsonCursor opt_cur;
        assert(!dict_cur.field_opt("non-existent key", &opt_cur)!!);
    };
}

fn void test_unicode_parsing() @test
{
    // Unicode without escape sequences.
    @pool()
    {
        // Code points 'pč∞🙈'.
        String s = "\"1-byte code point 'p', 2-byte code point '\xc4\x8d', 3-byte code point '\xe2\x88\x9e', 4-byte code point '\xf0\x9f\x99\x88'\"";
        String input = s.tcopy();

        usz max_depth;
        usz parsed_bytes;
        Pos parsed_pos;
        UJsonValue root = ujson::parse_prefix_and_mutate_input(
            input,
            out_max_depth: &max_depth,
            out_parsed_bytes: &parsed_bytes,
            out_parsed_pos: &parsed_pos)!!;
        assert(max_depth == 0);
        assert(parsed_bytes == 43 + 2 + 22 + 3 + 22 + 4 + 2);
        assert(parsed_pos.line == 0);
        assert(parsed_pos.code_point == 43 + 1 + 22 + 1 + 22 + 1 + 2);

        UJsonReader reader;
        reader.init(root, mem)!!;
        defer reader.free();

        UJsonCursor cur = reader.cursor();
        // Reader reads the same string as `s` but without double quotes.
        assert(cur.str()!! == s[1 .. ^2]);
    };

    // Unicode with `\uXXXX` escape sequences.
    @pool()
    {
        // Code points 'pč∞🙈'. The last code point intetionally used lower case hex digits.
        String s = "\"1-byte cp '\\u0070', 2-byte cp '\\u010D', 3-byte cp '\\u221E', 4-byte cp '\\ud83d\\ude48'\"";
        String input = s.tcopy();

        usz max_depth;
        usz parsed_bytes;
        Pos parsed_pos;
        UJsonValue root = ujson::parse_prefix_and_mutate_input(
            input,
            out_max_depth: &max_depth,
            out_parsed_bytes: &parsed_bytes,
            out_parsed_pos: &parsed_pos)!!;

        assert(max_depth == 0);
        assert(parsed_bytes == 12 + 6 + 14 + 6 + 14 + 6 + 14 + 12 + 2);
        assert(parsed_pos.line == 0);
        assert(parsed_pos.code_point == parsed_bytes);

        UJsonReader reader;
        reader.init(root, mem)!!;
        defer reader.free();

        UJsonCursor cur = reader.cursor();
        // Reader reads string where escape sequences are replaced by actual code points.
        assert(cur.str()!! == "1-byte cp 'p', 2-byte cp 'č', 3-byte cp '∞', 4-byte cp '🙈'");
    };

    // Overlong encodings are rejected.
    @pool()
    {
        // 1-byte code point `p` encoded in 2, 3 and 4 bytes.
        {
            String cp1as2 = "\"Foo \xC1\xB0 bar\"";
            String input = cp1as2.tcopy();

            usz max_depth;
            usz parsed_bytes;
            Pos parsed_pos;
            UJsonValue? root = ujson::parse_prefix_and_mutate_input(
                input,
                out_max_depth: &max_depth,
                out_parsed_bytes: &parsed_bytes,
                out_parsed_pos: &parsed_pos);

            assert(max_depth == 0);
            assert(parsed_bytes == 5);
            assert(parsed_pos.line == 0);
            assert(parsed_pos.code_point == 5);
            assert(@catch(root) == ujson::INVALID_UTF8);
        }
        {
            String cp1as3 = "\"Foo \xE0\x81\xB0 bar\"";
            String input = cp1as3.tcopy();

            usz max_depth;
            usz parsed_bytes;
            Pos parsed_pos;
            UJsonValue? root = ujson::parse_prefix_and_mutate_input(
                input,
                out_max_depth: &max_depth,
                out_parsed_bytes: &parsed_bytes,
                out_parsed_pos: &parsed_pos);

            assert(max_depth == 0);
            assert(parsed_bytes == 5);
            assert(parsed_pos.line == 0);
            assert(parsed_pos.code_point == 5);
            assert(@catch(root) == ujson::INVALID_UTF8);
        }
        {
            String cp1as4 = "\"Foo \xF0\x80\x81\xB0 bar\"";
            String input = cp1as4.tcopy();

            usz max_depth;
            usz parsed_bytes;
            Pos parsed_pos;
            UJsonValue? root = ujson::parse_prefix_and_mutate_input(
                input,
                out_max_depth: &max_depth,
                out_parsed_bytes: &parsed_bytes,
                out_parsed_pos: &parsed_pos);

            assert(max_depth == 0);
            assert(parsed_bytes == 5);
            assert(parsed_pos.line == 0);
            assert(parsed_pos.code_point == 5);
            assert(@catch(root) == ujson::INVALID_UTF8);
        }

        // 2-byte code point `č` encoded in 3 and 4 bytes.
        {
            String cp2as3 = "\"\xE0\x84\x8D\"";
            String input = cp2as3.tcopy();

            usz max_depth;
            usz parsed_bytes;
            Pos parsed_pos;
            UJsonValue? root = ujson::parse_prefix_and_mutate_input(
                input,
                out_max_depth: &max_depth,
                out_parsed_bytes: &parsed_bytes,
                out_parsed_pos: &parsed_pos);

            assert(max_depth == 0);
            assert(parsed_bytes == 1);
            assert(parsed_pos.line == 0);
            assert(parsed_pos.code_point == 1);
            assert(@catch(root) == ujson::INVALID_UTF8);
        }
        {
            String cp2as4 = "\"\xF0\x80\x84\x8D\"";
            String input = cp2as4.tcopy();

            usz max_depth;
            usz parsed_bytes;
            Pos parsed_pos;
            UJsonValue? root = ujson::parse_prefix_and_mutate_input(
                input,
                out_max_depth: &max_depth,
                out_parsed_bytes: &parsed_bytes,
                out_parsed_pos: &parsed_pos);

            assert(max_depth == 0);
            assert(parsed_bytes == 1);
            assert(parsed_pos.line == 0);
            assert(parsed_pos.code_point == 1);
            assert(@catch(root) == ujson::INVALID_UTF8);
        }

        // 3-byte code point `∞` encoded in 4 bytes.
        {
            String cp3as4 = "\"\xF0\x82\x88\x9E\"";
            String input = cp3as4.tcopy();

            usz max_depth;
            usz parsed_bytes;
            Pos parsed_pos;
            UJsonValue? root = ujson::parse_prefix_and_mutate_input(
                input,
                out_max_depth: &max_depth,
                out_parsed_bytes: &parsed_bytes,
                out_parsed_pos: &parsed_pos);

            assert(max_depth == 0);
            assert(parsed_bytes == 1);
            assert(parsed_pos.line == 0);
            assert(parsed_pos.code_point == 1);
            assert(@catch(root) == ujson::INVALID_UTF8);
        }

        // 4-byte code point `🙈` encoded in 5 bytes.
        {
            String cp4as5 = "\"\xf8\x80\x9F\x99\x88\"";
            String input = cp4as5.tcopy();

            usz max_depth;
            usz parsed_bytes;
            Pos parsed_pos;
            UJsonValue? root = ujson::parse_prefix_and_mutate_input(
                input,
                out_max_depth: &max_depth,
                out_parsed_bytes: &parsed_bytes,
                out_parsed_pos: &parsed_pos);

            assert(max_depth == 0);
            assert(parsed_bytes == 1);
            assert(parsed_pos.line == 0);
            assert(parsed_pos.code_point == 1);
            assert(@catch(root) == ujson::INVALID_UTF8);
        }
    };

    // Code points from surrogate range are rejected.
    @pool()
    {
        // Valid treasure chest `🪎` (4 bytes) followed by space and surrogate.
        String s = "\"\xf0\x9f\xaa\x8e \xED\xA0\x80\"";
        String input = s.tcopy();

        usz max_depth;
        usz parsed_bytes;
        Pos parsed_pos;
        UJsonValue? root = ujson::parse_prefix_and_mutate_input(
            input,
            out_max_depth: &max_depth,
            out_parsed_bytes: &parsed_bytes,
            out_parsed_pos: &parsed_pos);

        assert(max_depth == 0);
        assert(parsed_bytes == 6);
        assert(parsed_pos.line == 0);
        assert(parsed_pos.code_point == 3);
        assert(@catch(root) == ujson::INVALID_UTF8);
    };

    // Incomplete code point is rejected.
    @pool()
    {
        // Incomplete treasure chest `🪎` (only 3 bytes instead of 4) followed by ASCII.
        String s = "\"\xf0\x9f\xaaHello\"";
        String input = s.tcopy();

        usz max_depth;
        usz parsed_bytes;
        Pos parsed_pos;
        UJsonValue? root = ujson::parse_prefix_and_mutate_input(
            input,
            out_max_depth: &max_depth,
            out_parsed_bytes: &parsed_bytes,
            out_parsed_pos: &parsed_pos);

        assert(max_depth == 0);
        assert(parsed_bytes == 1);
        assert(parsed_pos.line == 0);
        assert(parsed_pos.code_point == 1);
        assert(@catch(root) == ujson::INVALID_UTF8);
    };

    // Code point starting with continuation byte is rejected.
    @pool()
    {
        String s = "\"Hello\x80World\"";
        String input = s.tcopy();

        usz max_depth;
        usz parsed_bytes;
        Pos parsed_pos;
        UJsonValue? root = ujson::parse_prefix_and_mutate_input(
            input,
            out_max_depth: &max_depth,
            out_parsed_bytes: &parsed_bytes,
            out_parsed_pos: &parsed_pos);

        assert(max_depth == 0);
        assert(parsed_bytes == 6);
        assert(parsed_pos.line == 0);
        assert(parsed_pos.code_point == 6);
        assert(@catch(root) == ujson::INVALID_UTF8);
    };
}

fn void test_unexpected_end() @test
{
    String[*] samples = {
        " \"hello",

        "-",
        "1.",
        "1.2e",
        "1.2e+",
        "1.2e-",

        "[",
        "[1",
        "[1,",

        "{",
        "{ \"foo\"",
        "{ \"foo\": ",
        "{ \"foo\": true",
        "{ \"foo\": true, ",
    };

    foreach (s : samples)
    {
        @pool()
        {
            String input = s.tcopy();

            usz max_depth;
            usz parsed_bytes;
            Pos parsed_pos;
            UJsonValue? root = ujson::parse_prefix_and_mutate_input(
                input,
                out_max_depth: &max_depth,
                out_parsed_bytes: &parsed_bytes,
                out_parsed_pos: &parsed_pos);

            assert(max_depth == (@ok(s.index_of_chars({ '{', '[' })) ? 1 : 0));
            assert(parsed_bytes == s.len);
            assert(parsed_pos.line == 0);
            assert(parsed_pos.code_point == s.len);
            assert(@catch(root) == ujson::UNEXPECTED_END_OF_INPUT);
        };
    }
}

fn void test_invalid_token() @test
{
    String[*] samples = {
        "  nul",
        " t",
        " fa",
        "\thello",
    };
    foreach (s : samples)
    {
        @pool()
        {
            String input = s.tcopy();

            usz max_depth;
            usz parsed_bytes;
            Pos parsed_pos;
            UJsonValue? root = ujson::parse_prefix_and_mutate_input(
                input,
                out_max_depth: &max_depth,
                out_parsed_bytes: &parsed_bytes,
                out_parsed_pos: &parsed_pos);

            assert(max_depth == 0);
            usz skipped_spaces = s.len - s.trim_left().len;
            assert(parsed_bytes == skipped_spaces);
            assert(parsed_pos.line == 0);
            assert(parsed_pos.code_point == skipped_spaces);
            assert(@catch(root) == ujson::INVALID_TOKEN);
        };
    }
}

fn void test_already_used_keys() @test
{
    @pool()
    {
        String s = `{ "a": 1, "b": 2, "c": [true, { "d": 3, "e": 4 }] }`;
        String input = s.tcopy();

        UJsonValue root = ujson::parse_prefix_and_mutate_input(input)!!;

        UJsonReader reader;
        reader.init(root, mem)!!;
        defer reader.free();

        UJsonCursor cur = reader.cursor();
        UJsonDictCursor dict_cur = cur.dict()!!;
        assert(dict_cur.field("a")!!.num_as_str()!! == "1");
        assert(dict_cur.field("b")!!.num_as_str()!! == "2");

        UJsonListCursor list_cur = dict_cur.field("c")!!.list()!!;

        {
            UJsonDictCursor nested_dict_cur = list_cur[1].dict()!!;
            assert(nested_dict_cur.field("d")!!.num_as_str()!! == "3");
            // Intentionally use `d` again.
            assert(@catch(nested_dict_cur.field("d")) == ujson::FIELD_ALREADY_USED);
        }

        // Intentionally use `a` again.
        assert(@catch(dict_cur.field("a")) == ujson::FIELD_ALREADY_USED);
    };
}

fn void test_unused_keys() @test
{
    @pool()
    {
        String s = `{ "a": 1, "b": 2, "c": [true, { "d": 3, "e": 4 }] }`;
        String input = s.tcopy();

        UJsonValue root = ujson::parse_prefix_and_mutate_input(input)!!;

        UJsonReader reader;
        reader.init(root, mem)!!;
        defer reader.free();

        UJsonCursor cur = reader.cursor();
        UJsonDictCursor dict_cur = cur.dict()!!;

        assert(dict_cur.field("a")!!.num_as_long()!! == 1);
        // Intentionally don't use `b`.

        UJsonListCursor list_cur = dict_cur.field("c")!!.list()!!;
        cur = list_cur.get(1);
        {
            UJsonDictCursor nested_dict_cur = cur.dict()!!;
            nested_dict_cur.field("d")!!;
            // Intentionally don't use `e`.
        }

        // Find unused keys.
        {
            SList{UJsonPathSegment} path;
            path.init(mem);
            defer path.free();

            bool unused_b, unused_e;
            while FIND_UNUSED_KEYS: (true)
            {
                reader.find_next_unused_field(&path)!!;

                switch (path.len())
                {
                    case 0:
                        // We found everything.
                        break FIND_UNUSED_KEYS;
                    case 1:
                        assert(path[0].parent == reader.root);
                        assert(path[0].idx == 0);
                        assert(path[0].key == "b");

                        assert(!unused_b);
                        unused_b = true;
                    case 3:
                        assert(path[0].parent == reader.root);
                        assert(path[0].idx == 0);
                        assert(path[0].key == "c");
                        assert(path[1].parent == ujson::make_value(list_cur.list, LIST));
                        assert(path[1].idx == 1);
                        assert(path[1].key == "");
                        assert(path[2].parent == cur.value);
                        assert(path[2].idx == 0);
                        assert(path[2].key == "e");

                        assert(!unused_e);
                        unused_e = true;
                    default:
                        // Unexpected length.
                        assert(false);
                }
            }
            assert(unused_b && unused_e);
        }
    };
}

