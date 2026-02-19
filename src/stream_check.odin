package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "vendor:curl"

// Standard linker requirements for static libcurl on Windows
foreign import libcurl {"system:libcurl.lib", "system:ws2_32.lib", "system:wldap32.lib", "system:crypt32.lib", "system:advapi32.lib", "system:normaliz.lib"}

// GraphQL request structure
GraphQLRequest :: struct
{
	query: string,
}

// libcurl write callback
_write_cb :: proc "c" (ptr: rawptr, size, nmemb: c.size_t, userdata: rawptr) -> c.size_t
{
	context = {}
	sb := (^strings.Builder)(userdata)
	bytes := ([^]u8)(ptr)[:size * nmemb]
	strings.write_bytes(sb, bytes)
	return size * nmemb
}

gql_request :: proc(query: string) -> (response: string, ok: bool)
{
	handle := curl.easy_init()
	if handle == nil
	{
		return "", false
	}
	defer curl.easy_cleanup(handle)

	// Set up headers
	headers: ^curl.slist
	headers = curl.slist_append(headers, "Client-ID: kimne78kx3ncx6brgo4mv6wki5h1ko")
	headers = curl.slist_append(headers, "Content-Type: application/json")
	headers = curl.slist_append(headers, "User-Agent: Mozilla/5.0")
	headers = curl.slist_append(headers, "Accept-Encoding: gzip, deflate")
	defer curl.slist_free_all(headers)

	curl.easy_setopt(handle, .URL, "https://gql.twitch.tv/gql")
	curl.easy_setopt(handle, .HTTPHEADER, headers)
	curl.easy_setopt(handle, .POST, i64(1))

	req := GraphQLRequest \
	{
		query = query,
	}
	json_data, json_err := json.marshal(req, {pretty = false}, context.temp_allocator)
	if json_err != nil
	{
		return "", false
	}

	curl.easy_setopt(handle, .POSTFIELDS, raw_data(json_data))
	curl.easy_setopt(handle, .POSTFIELDSIZE, i64(len(json_data)))

	// Response builder
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	curl.easy_setopt(handle, .WRITEFUNCTION, _write_cb)
	curl.easy_setopt(handle, .WRITEDATA, &sb)
	curl.easy_setopt(handle, .TIMEOUT, i64(10))

	// SSL Settings (Windows compatibility)
	curl.easy_setopt(handle, .SSL_VERIFYPEER, i64(0))
	curl.easy_setopt(handle, .SSL_VERIFYHOST, i64(0))

	if res := curl.easy_perform(handle); res != .E_OK
	{
		return "", false
	}

	response = strings.to_string(sb)
	return response, true
}

stream_check_is_live :: proc(channel: string) -> bool
{
	name := channel
	if strings.has_prefix(name, "#") do name = name[1:]

	// NEED to escape braces fot tprintf/odin
	query := fmt.tprintf("query {{ user(login:\"%s\") {{ stream {{ id }} }} }}", name)

	resp, ok := gql_request(query)
	if !ok do return false

	return !strings.contains(resp, `"stream":null`) && strings.contains(resp, `"stream":`)
}


stream_check_viewer_count :: proc(channel: string) -> int
{
	name := channel
	if strings.has_prefix(name, "#") do name = name[1:]

	// NEED to escape braces fot tprintf/odin
	query := fmt.tprintf("query {{ user(login:\"%s\") {{ stream {{ viewersCount }} }} }}", name)

	resp, ok := gql_request(query)
	if !ok do return -1

	if strings.contains(resp, `"stream":null`) do return 0

	needle := `"viewersCount":`
	pos := strings.index(resp, needle)
	if pos == -1 do return -1

	rest := resp[pos + len(needle):]
	end := 0
	for end < len(rest) && rest[end] >= '0' && rest[end] <= '9'
	{
		end += 1
	}

	if end == 0 do return -1

	viewers, _ := strconv.parse_int(rest[:end])
	return viewers
}

stream_check_status :: proc(channel: string) -> (bool, int)
{
	name := channel
	if strings.has_prefix(name, "#") do name = name[1:]

	query := fmt.tprintf("query {{ user(login:\"%s\") {{ stream {{ id viewersCount }} }} }}", name)
	resp, ok := gql_request(query)
	if !ok do return false, -1

	if strings.contains(resp, `"stream":null`)
	{
		return false, 0
	}

	is_live := strings.contains(resp, `"id":`)
	if !is_live do return false, 0

	viewers := 0
	needle := `"viewersCount":`
	if pos := strings.index(resp, needle); pos != -1
	{
		rest := resp[pos + len(needle):]
		viewers, _ = strconv.parse_int(rest)
	}

	return is_live, viewers
}
