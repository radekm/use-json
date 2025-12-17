import std;
import btree;
import use_json;

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
        list.items[0] = use_json::make_value(null, TRUE);
        list.items[1] = use_json::make_value(null, NULL);  // Not necessary because this value is zero.
        list.items[2] = use_json::make_value(number, NUMBER);
        list.items[3] = use_json::make_value(string_with_quote, STRING);
        UJsonDict* empty_dict = mem::tnew(UJsonDict);
        empty_dict.fields.init(tmem);

        UJsonDict* top_level_dict = mem::tnew(UJsonDict);
        top_level_dict.fields.init(tmem);
        {
            // Key `list`.
            String key = data[2 : 4];
            BTreeSlot{UJsonField} slot = top_level_dict.fields.@get_slot(
                fn int(String key, UJsonField item_from_tree) => use_json::compare_keys(key, item_from_tree.key),
                key);
            slot.item.key = key;
            slot.item.value = use_json::make_value(list, LIST);
        }
        {
            // Key `empty dict`.
            String key = data[39 : 10];
            BTreeSlot{UJsonField} slot = top_level_dict.fields.@get_slot(
                fn int(String key, UJsonField item_from_tree) => use_json::compare_keys(key, item_from_tree.key),
                key);
            slot.item.key = key;
            slot.item.value = use_json::make_value(empty_dict, DICT);
        }

        UJsonReader reader;
        reader.init(use_json::make_value(top_level_dict, DICT), tmem)!!;

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
        UJsonValue root = use_json::make_value(null, FALSE);
        UJsonReader reader;
        reader.init(root, tmem)!!;
        UJsonCursor cur = reader.cursor();

        int line_before = $$LINE;
        fault excuse = @catch(cur.dict());
        assert(excuse == use_json::INVALID_KIND);
        assert(reader.last_error_file == $$FILE);
        assert(reader.last_error_func == $$FUNC);
        assert(reader.last_error_line == line_before + 1);
    };
}
