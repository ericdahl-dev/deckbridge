// Just enough JSON for the test to read feed/examples.json: objects, arrays, strings, numbers, true, false, null.
#pragma once

#include <cstdlib>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace json_mini {

struct Value {
    enum class Kind { null, boolean, number, string, array, object } kind = Kind::null;
    bool boolean = false;
    double number = 0;
    std::string string;
    std::vector<Value> array;
    std::map<std::string, Value> object;

    const Value& operator[](const std::string& key) const {
        auto found = object.find(key);
        if (found == object.end()) throw std::runtime_error("no key " + key);
        return found->second;
    }
    bool has(const std::string& key) const { return object.count(key) != 0; }
};

class Reader {
public:
    explicit Reader(const std::string& text) : text_(text) {}

    Value read() {
        Value v = value();
        space();
        if (at_ != text_.size()) fail("trailing text");
        return v;
    }

private:
    const std::string& text_;
    size_t at_ = 0;

    [[noreturn]] void fail(const std::string& why) { throw std::runtime_error(why + " at " + std::to_string(at_)); }
    void space() {
        while (at_ < text_.size() && (text_[at_] == ' ' || text_[at_] == '\n' || text_[at_] == '\r' || text_[at_] == '\t')) ++at_;
    }
    char peek() {
        space();
        if (at_ >= text_.size()) fail("unexpected end");
        return text_[at_];
    }
    void expect(char c) {
        if (peek() != c) fail(std::string("expected ") + c);
        ++at_;
    }
    bool word(const char* w) {
        size_t n = std::char_traits<char>::length(w);
        if (text_.compare(at_, n, w) != 0) return false;
        at_ += n;
        return true;
    }

    static void put_utf8(std::string& out, unsigned code) {
        if (code < 0x80) {
            out += static_cast<char>(code);
        } else if (code < 0x800) {
            out += static_cast<char>(0xC0 | code >> 6);
            out += static_cast<char>(0x80 | (code & 0x3F));
        } else if (code < 0x10000) {
            out += static_cast<char>(0xE0 | code >> 12);
            out += static_cast<char>(0x80 | (code >> 6 & 0x3F));
            out += static_cast<char>(0x80 | (code & 0x3F));
        } else {
            out += static_cast<char>(0xF0 | code >> 18);
            out += static_cast<char>(0x80 | (code >> 12 & 0x3F));
            out += static_cast<char>(0x80 | (code >> 6 & 0x3F));
            out += static_cast<char>(0x80 | (code & 0x3F));
        }
    }

    unsigned hex4() {
        if (at_ + 4 > text_.size()) fail("short \\u");
        unsigned code = static_cast<unsigned>(std::strtoul(text_.substr(at_, 4).c_str(), nullptr, 16));
        at_ += 4;
        return code;
    }

    std::string string() {
        expect('"');
        std::string out;
        while (true) {
            if (at_ >= text_.size()) fail("unterminated string");
            char c = text_[at_++];
            if (c == '"') return out;
            if (c != '\\') {
                out += c;
                continue;
            }
            char e = text_[at_++];
            switch (e) {
                case 'n': out += '\n'; break;
                case 't': out += '\t'; break;
                case 'r': out += '\r'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'u': {
                    unsigned code = hex4();
                    if (code >= 0xD800 && code <= 0xDBFF && word("\\u")) code = 0x10000 + ((code - 0xD800) << 10) + (hex4() - 0xDC00);
                    put_utf8(out, code);
                    break;
                }
                default: out += e;
            }
        }
    }

    Value value() {
        Value v;
        char c = peek();
        if (c == '{') {
            v.kind = Value::Kind::object;
            ++at_;
            if (peek() == '}') return ++at_, v;
            while (true) {
                std::string key = string();
                expect(':');
                v.object[key] = value();
                if (peek() == ',') { ++at_; continue; }
                expect('}');
                return v;
            }
        }
        if (c == '[') {
            v.kind = Value::Kind::array;
            ++at_;
            if (peek() == ']') return ++at_, v;
            while (true) {
                v.array.push_back(value());
                if (peek() == ',') { ++at_; continue; }
                expect(']');
                return v;
            }
        }
        if (c == '"') {
            v.kind = Value::Kind::string;
            v.string = string();
            return v;
        }
        if (word("true")) { v.kind = Value::Kind::boolean; v.boolean = true; return v; }
        if (word("false")) { v.kind = Value::Kind::boolean; return v; }
        if (word("null")) return v;
        char* end = nullptr;
        v.number = std::strtod(text_.c_str() + at_, &end);
        if (end == text_.c_str() + at_) fail("bad value");
        v.kind = Value::Kind::number;
        at_ = static_cast<size_t>(end - text_.c_str());
        return v;
    }
};

inline Value parse(const std::string& text) { return Reader(text).read(); }

}  // namespace json_mini
