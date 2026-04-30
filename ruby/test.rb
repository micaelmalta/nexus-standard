# frozen_string_literal: true
# NXS parity tests — verifies the Ruby reader against the 1000-record JSON fixture.
#
# Usage: ruby ruby/test.rb [fixtures_dir]
#   e.g. ruby ruby/test.rb js/fixtures

require "json"
require_relative "nxs"

PASS = "\e[32mPASS\e[0m"
FAIL = "\e[31mFAIL\e[0m"

def check(label, &blk)
  result = blk.call
  if result
    puts "  #{PASS}  #{label}"
    true
  else
    puts "  #{FAIL}  #{label}"
    false
  end
rescue => e
  puts "  #{FAIL}  #{label} — exception: #{e}"
  false
end

fixture_dir = ARGV[0] || "../js/fixtures"
nxb_path    = File.join(fixture_dir, "records_1000.nxb")
json_path   = File.join(fixture_dir, "records_1000.json")

unless File.exist?(nxb_path) && File.exist?(json_path)
  abort "Fixtures not found in #{fixture_dir}"
end

buf     = File.binread(nxb_path)
json_str = File.read(json_path, encoding: "UTF-8")
reader  = Nxs::Reader.new(buf)
json    = JSON.parse(json_str)

passes = 0
fails  = 0

puts
puts "NXS Ruby Reader — Parity Tests"
puts "━" * 60
puts "  Fixture: #{nxb_path}"
puts

[
  check("record_count == 1000") { reader.record_count == 1000 },
  check("keys includes 'username'") { reader.keys.include?("username") },
  check("keys includes 'score'")    { reader.keys.include?("score")    },
  check("keys includes 'active'")   { reader.keys.include?("active")   },
  check("keys includes 'email'")    { reader.keys.include?("email")    },

  check("record(42).get_str('username') == json[42]['username']") {
    reader.record(42).get_str("username") == json[42]["username"]
  },

  check("record(0).get_str('username') == json[0]['username']") {
    reader.record(0).get_str("username") == json[0]["username"]
  },

  check("record(999).get_str('username') == json[999]['username']") {
    reader.record(999).get_str("username") == json[999]["username"]
  },

  check("record(500).get_f64('score').round(6) == json[500]['score'].round(6)") {
    nxs_val  = reader.record(500).get_f64("score")
    json_val = json[500]["score"].to_f
    nxs_val.round(6) == json_val.round(6)
  },

  check("record(42).get_f64('score') == json[42]['score']") {
    reader.record(42).get_f64("score").round(6) == json[42]["score"].to_f.round(6)
  },

  check("record(999).get_bool('active') == json[999]['active']") {
    reader.record(999).get_bool("active") == json[999]["active"]
  },

  check("record(0).get_bool('active') == json[0]['active']") {
    reader.record(0).get_bool("active") == json[0]["active"]
  },

  check("record(1).get_bool('active') (spot-check)") {
    reader.record(1).get_bool("active") == json[1]["active"]
  },

  check("record(42).get_i64('id') == json[42]['id']") {
    reader.record(42).get_i64("id") == json[42]["id"]
  },

  check("record(999).get_i64('age') == json[999]['age']") {
    reader.record(999).get_i64("age") == json[999]["age"]
  },

  check("sum_f64('score').round(4) == json.sum{score}.round(4)") {
    nxs_sum  = reader.sum_f64("score")
    json_sum = json.sum { |r| r["score"].to_f }
    nxs_sum.round(4) == json_sum.round(4)
  },

  check("sum_i64('id') == json.sum{id}") {
    nxs_sum  = reader.sum_i64("id")
    json_sum = json.sum { |r| r["id"].to_i }
    nxs_sum == json_sum
  },

  check("min_f64('score') is a Float") {
    v = reader.min_f64("score")
    v.is_a?(Float)
  },

  check("max_f64('score') >= min_f64('score')") {
    reader.max_f64("score") >= reader.min_f64("score")
  },

  check("out-of-bounds record(-1) raises") {
    begin
      reader.record(-1)
      false
    rescue Nxs::NxsError => e
      e.code == "ERR_OUT_OF_BOUNDS"
    end
  },

  check("out-of-bounds record(1000) raises") {
    begin
      reader.record(1000)
      false
    rescue Nxs::NxsError => e
      e.code == "ERR_OUT_OF_BOUNDS"
    end
  },

  check("unknown key returns nil") {
    reader.record(0).get_str("__nonexistent__").nil?
  },
].each { |r| r ? (passes += 1) : (fails += 1) }

# ── Security tests ──────────────────────────────────────────────────────────
[
  check("bad magic raises ERR_BAD_MAGIC") {
    bad = buf.dup; bad.setbyte(0, 0x00)
    begin Nxs::Reader.new(bad); false
    rescue Nxs::NxsError => e; e.code == "ERR_BAD_MAGIC"
    end
  },

  check("truncated file raises NxsError") {
    begin Nxs::Reader.new(buf[0, 16]); false
    rescue Nxs::NxsError; true
    end
  },

  check("corrupt DictHash raises ERR_DICT_MISMATCH") {
    bad = buf.dup; bad.setbyte(8, bad.getbyte(8) ^ 0xFF)
    begin Nxs::Reader.new(bad); false
    rescue Nxs::NxsError => e; e.code == "ERR_DICT_MISMATCH"
    end
  },
].each { |r| r ? (passes += 1) : (fails += 1) }

puts
puts "━" * 60
puts "  Results: #{passes} passed, #{fails} failed"
puts

exit(fails == 0 ? 0 : 1)
