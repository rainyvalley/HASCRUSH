#!/usr/bin/env bats
# mcp_parse_entry (rootfs/lib.sh): the single-jq, NUL-delimited parse of one
# mcp_servers entry into the _mf array that run.sh's loop indexes by position.

load 'test_helper'

# _mf layout: 0 name, 1 url, 2 command, 3 token, 4 token_url, 5 timeout,
# 6 argsok, 7.. args

@test "http entry with a hyphenated name keeps every scalar field" {
  mcp_parse_entry '{"name":"home-assistant","url":"http://test.invalid:8123/mcp","token":"t0k","token_url":"https://test.invalid/t","timeout":15}'
  [ "${_mf[0]}" = "home-assistant" ]
  [ "${_mf[1]}" = "http://test.invalid:8123/mcp" ]
  [ "${_mf[2]}" = "" ]
  [ "${_mf[3]}" = "t0k" ]
  [ "${_mf[4]}" = "https://test.invalid/t" ]
  [ "${_mf[5]}" = "15" ]
  [ "${_mf[6]}" = "1" ]
  [ "${#_mf[@]}" -eq 7 ]
}

@test "stdio entry: command, args array in order" {
  mcp_parse_entry '{"name":"openscad","command":"socat","args":["STDIO","TCP:192.0.2.5:3010"],"timeout":20}'
  [ "${_mf[0]}" = "openscad" ]
  [ "${_mf[1]}" = "" ]
  [ "${_mf[2]}" = "socat" ]
  [ "${_mf[5]}" = "20" ]
  [ "${_mf[6]}" = "1" ]
  [ "${#_mf[@]}" -eq 9 ]
  [ "${_mf[7]}" = "STDIO" ]
  [ "${_mf[8]}" = "TCP:192.0.2.5:3010" ]
}

@test "absent args counts as a valid empty array" {
  mcp_parse_entry '{"name":"x","command":"true"}'
  [ "${_mf[6]}" = "1" ]
  [ "${#_mf[@]}" -eq 7 ]
}

@test "args as a string flags argsok 0 and yields no arg elements" {
  mcp_parse_entry '{"name":"x","command":"socat","args":"STDIO TCP:192.0.2.5:1"}'
  [ "${_mf[6]}" = "0" ]
  [ "${#_mf[@]}" -eq 7 ]
}

@test "args as a number or object flags argsok 0" {
  mcp_parse_entry '{"name":"x","command":"c","args":5}'
  [ "${_mf[6]}" = "0" ]
  [ "${#_mf[@]}" -eq 7 ]
  mcp_parse_entry '{"name":"x","command":"c","args":{"a":"b"}}'
  [ "${_mf[6]}" = "0" ]
  [ "${#_mf[@]}" -eq 7 ]
}

@test "empty-string args are kept as (empty) elements, in position" {
  mcp_parse_entry '{"name":"x","command":"c","args":["a","","b"]}'
  [ "${#_mf[@]}" -eq 10 ]
  [ "${_mf[7]}" = "a" ]
  [ "${_mf[8]}" = "" ]
  [ "${_mf[9]}" = "b" ]
}

@test "args containing spaces stay one element each" {
  mcp_parse_entry '{"name":"x","command":"c","args":["--label","hello world","/a b/c"]}'
  [ "${#_mf[@]}" -eq 10 ]
  [ "${_mf[8]}" = "hello world" ]
  [ "${_mf[9]}" = "/a b/c" ]
}

@test "missing fields parse as empty strings, not shifted values" {
  mcp_parse_entry '{"url":"http://test.invalid/mcp"}'
  [ "${_mf[0]}" = "" ]
  [ "${_mf[1]}" = "http://test.invalid/mcp" ]
  [ "${_mf[3]}" = "" ]
  [ "${_mf[5]}" = "" ]
}

@test "an embedded NUL escape is dropped and cannot shift fields" {
  mcp_parse_entry '{"name":"a\u0000b","url":"http://test.invalid/m","command":""}'
  [ "${_mf[0]}" = "ab" ]
  [ "${_mf[1]}" = "http://test.invalid/m" ]
  [ "${#_mf[@]}" -eq 7 ]
}

@test "non-object input yields no fields without failing the caller" {
  run mcp_parse_entry 'not json'
  [ "$status" -eq 0 ]
}
