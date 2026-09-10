// tests/test_pk_protocol.c: pk_protocol 的主机测试,不依赖 ESP-IDF。
#include "pk_protocol.h"

#include <stdio.h>
#include <string.h>

static int s_failures;

#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); \
            s_failures++;                                                        \
        }                                                                        \
    } while (0)

#define CHECK_STR(actual, expected)                                              \
    do {                                                                         \
        const char *a_ = (actual);                                               \
        const char *e_ = (expected);                                             \
        if (strcmp(a_, e_) != 0) {                                               \
            fprintf(stderr, "%s:%d: expected \"%s\", got \"%s\"\n",              \
                    __FILE__, __LINE__, e_, a_);                                 \
            s_failures++;                                                        \
        }                                                                        \
    } while (0)

static bool parse(const char *line, pk_cmd_t *cmd)
{
    return pk_parse_command(line, strlen(line), cmd);
}

static void test_format_messages(void)
{
    char buf[PK_MSG_MAX];

    CHECK(pk_format_hello(buf, sizeof(buf), "1.0.0", 0x9f3a21c4) == strlen(buf));
    CHECK_STR(buf, "{\"t\":\"hello\",\"fw\":\"passport-keys\",\"proto\":1,\"ver\":\"1.0.0\",\"boot\":\"9f3a21c4\"}\n");

    CHECK(pk_format_button(buf, sizeof(buf), PK_KEY_DOWN, 42, 0x1) > 0);
    CHECK_STR(buf, "{\"t\":\"btn\",\"k\":\"down\",\"e\":\"press\",\"seq\":42,\"boot\":\"00000001\"}\n");

    CHECK(pk_format_battery(buf, sizeof(buf), -1, 4012) > 0);
    CHECK_STR(buf, "{\"t\":\"bat\",\"soc\":-1,\"mv\":4012}\n");

    CHECK(pk_format_pong(buf, sizeof(buf)) > 0);
    CHECK_STR(buf, "{\"t\":\"pong\"}\n");

    CHECK(pk_format_ack(buf, sizeof(buf), "labels") > 0);
    CHECK_STR(buf, "{\"t\":\"ack\",\"cmd\":\"labels\"}\n");

    // 放不下或参数越界时返回 0。
    char tiny[12];
    CHECK(pk_format_pong(tiny, sizeof(tiny)) == 0);
    CHECK(pk_format_button(buf, sizeof(buf), PK_KEY_COUNT, 1, 1) == 0);
    CHECK_STR(pk_key_name(PK_KEY_OK), "ok");
    CHECK_STR(pk_key_name(PK_KEY_COUNT), "?");
}

static void test_parse_simple_commands(void)
{
    pk_cmd_t cmd;
    CHECK(parse("{\"cmd\":\"hello\"}", &cmd) && cmd.type == PK_CMD_HELLO);
    CHECK(parse(" { \"cmd\" : \"ping\" , \"n\": -12.5e3, \"flag\": true, \"x\": null } ", &cmd) &&
          cmd.type == PK_CMD_PING);
    CHECK(parse("{\"cmd\":\"bye\"}\r\n", &cmd) && cmd.type == PK_CMD_BYE);
}

static void test_parse_labels(void)
{
    pk_cmd_t cmd;
    CHECK(parse("{\"cmd\":\"labels\",\"down\":\"Down\",\"ok\":\"Say \\\"hi\\\"\\/\",\"up\":\"Cmd+A\"}", &cmd));
    CHECK(cmd.type == PK_CMD_LABELS);
    CHECK(cmd.has_label[PK_KEY_UP] && cmd.has_label[PK_KEY_DOWN] && cmd.has_label[PK_KEY_OK]);
    CHECK_STR(cmd.label[PK_KEY_UP], "Cmd+A");
    CHECK_STR(cmd.label[PK_KEY_DOWN], "Down");
    CHECK_STR(cmd.label[PK_KEY_OK], "Say \"hi\"/");

    // 字段顺序无关;没出现的键 has_label 为 false,空字符串表示"未设置"。
    CHECK(parse("{\"up\":\"\",\"cmd\":\"labels\"}", &cmd));
    CHECK(cmd.has_label[PK_KEY_UP] && !cmd.has_label[PK_KEY_DOWN] && !cmd.has_label[PK_KEY_OK]);
    CHECK_STR(cmd.label[PK_KEY_UP], "");
}

static void test_parse_sanitizes_labels(void)
{
    pk_cmd_t cmd;
    // UTF-8 "中"(E4 B8 AD)、\u00e9、代理对 U+1F600 与转义控制字符。
    CHECK(parse("{\"cmd\":\"labels\",\"up\":\"A\xE4\xB8\xAD" "B\",\"down\":\"\\u00e9x\\u0041\","
                "\"ok\":\"\\ud83d\\ude00!\\t\"}", &cmd));
    CHECK_STR(cmd.label[PK_KEY_UP], "A?B");
    CHECK_STR(cmd.label[PK_KEY_DOWN], "?xA");
    CHECK_STR(cmd.label[PK_KEY_OK], "?! ");

    char line[200];
    snprintf(line, sizeof(line), "{\"cmd\":\"labels\",\"up\":\"%s\"}",
             "0123456789012345678901234567890123456789");
    CHECK(parse(line, &cmd));
    CHECK(strlen(cmd.label[PK_KEY_UP]) == PK_LABEL_MAX - 1);
}

static void test_parse_config(void)
{
    pk_cmd_t cmd;
    CHECK(parse("{\"cmd\":\"config\",\"screen_off\":10}", &cmd));
    CHECK(cmd.type == PK_CMD_CONFIG && cmd.has_screen_off && cmd.screen_off_s == 10);

    // 0 表示永不熄屏;字段顺序与空白无关。
    CHECK(parse(" { \"screen_off\" : 0 , \"cmd\" : \"config\" } ", &cmd));
    CHECK(cmd.type == PK_CMD_CONFIG && cmd.has_screen_off && cmd.screen_off_s == 0);

    CHECK(parse("{\"cmd\":\"config\",\"screen_off\":86400}", &cmd));
    CHECK(cmd.screen_off_s == PK_SCREEN_OFF_MAX_S);

    char buf[PK_MSG_MAX];
    CHECK(pk_format_ack(buf, sizeof(buf), "config") > 0);
    CHECK_STR(buf, "{\"t\":\"ack\",\"cmd\":\"config\"}\n");
}

static void test_parse_rejects_invalid(void)
{
    static const char *const bad[] = {
        "",
        "hello",
        "{}",
        "{\"cmd\":\"reboot\"}",
        "{\"cmd\":\"hello\"",
        "{\"cmd\":\"hello\"}x",
        "{\"cmd\":\"hello\",}",
        "{\"cmd\" \"hello\"}",
        "{\"cmd\":\"labels\",\"up\":{\"a\":1}}",
        "{\"cmd\":[1]}",
        "{\"cmd\":\"he\nllo\"}",
        "{\"cmd\":\"\\q\"}",
        "{\"cmd\":\"\\u12\"}",
        "{\"cmd\":\"hello\",\"n\":}",
        "{\"cmd\":\"hello",
        "{\"cmd\":\"config\"}",
        "{\"cmd\":\"config\",\"screen_off\":\"10\"}",
        "{\"cmd\":\"config\",\"screen_off\":-1}",
        "{\"cmd\":\"config\",\"screen_off\":1.5}",
        "{\"cmd\":\"config\",\"screen_off\":1e3}",
        "{\"cmd\":\"config\",\"screen_off\":010}",
        "{\"cmd\":\"config\",\"screen_off\":86401}",
        "{\"cmd\":\"config\",\"screen_off\":99999999999999999999}",
    };
    pk_cmd_t cmd;
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
        if (parse(bad[i], &cmd)) {
            fprintf(stderr, "accepted invalid command #%zu: %s\n", i, bad[i]);
            s_failures++;
        }
    }
}

typedef struct {
    char lines[4][PK_LINE_MAX];
    int count;
} collected_t;

static void collect(const char *line, size_t len, void *user)
{
    collected_t *c = user;
    if (c->count < 4) {
        memcpy(c->lines[c->count], line, len + 1);
    }
    c->count++;
}

static void feed(pk_line_t *line, const char *text, collected_t *c)
{
    pk_line_feed(line, (const uint8_t *)text, strlen(text), collect, c);
}

static void test_line_assembler(void)
{
    pk_line_t line;
    collected_t c = { 0 };
    pk_line_init(&line);

    feed(&line, "{\"cmd\":", &c);
    CHECK(c.count == 0);
    feed(&line, "\"ping\"}\r\n{\"cmd\"", &c);
    feed(&line, ":\"bye\"}\n\n\r\n", &c);
    CHECK(c.count == 2);
    CHECK_STR(c.lines[0], "{\"cmd\":\"ping\"}");
    CHECK_STR(c.lines[1], "{\"cmd\":\"bye\"}");

    // 超长行整行丢弃,下一行正常。
    memset(&c, 0, sizeof(c));
    uint8_t big[PK_LINE_MAX + 10];
    memset(big, 'x', sizeof(big));
    pk_line_feed(&line, big, sizeof(big), collect, &c);
    feed(&line, "tail\nok\n", &c);
    CHECK(c.count == 1);
    CHECK_STR(c.lines[0], "ok");

    // 恰好 PK_LINE_MAX - 1 字节的行可以完整收下。
    memset(&c, 0, sizeof(c));
    uint8_t exact[PK_LINE_MAX];
    memset(exact, 'y', sizeof(exact));
    exact[PK_LINE_MAX - 1] = '\n';
    pk_line_feed(&line, exact, sizeof(exact), collect, &c);
    CHECK(c.count == 1);
    CHECK(strlen(c.lines[0]) == PK_LINE_MAX - 1);
}

int main(void)
{
    test_format_messages();
    test_parse_simple_commands();
    test_parse_labels();
    test_parse_sanitizes_labels();
    test_parse_config();
    test_parse_rejects_invalid();
    test_line_assembler();

    if (s_failures) {
        fprintf(stderr, "pk_protocol tests: %d failure(s)\n", s_failures);
        return 1;
    }
    printf("pk_protocol tests: PASS\n");
    return 0;
}
