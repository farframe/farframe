#include <arpa/inet.h>
#include <chiaki/remote/holepunch.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define REQUIRE(condition) do { if(!(condition)) return __LINE__; } while(0)

int main(void)
{
	ChiakiHolepunchDeviceInfo *devices = (ChiakiHolepunchDeviceInfo *)(uintptr_t)1;
	size_t device_count = 99;
	REQUIRE(chiaki_holepunch_list_devices(
		"not-a-real-token",
		CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5,
		&devices,
		&device_count,
		NULL) == CHIAKI_ERR_UNINITIALIZED);
	REQUIRE(devices == NULL);
	REQUIRE(device_count == 0);
	chiaki_holepunch_free_device_list(&devices);

	char device_uid[CHIAKI_DUID_STR_SIZE] = "sentinel";
	size_t device_uid_size = sizeof(device_uid);
	REQUIRE(chiaki_holepunch_generate_client_device_uid(
		device_uid,
		&device_uid_size) == CHIAKI_ERR_UNINITIALIZED);
	REQUIRE(device_uid[0] == '\0');
	REQUIRE(device_uid_size == 0);

	REQUIRE(chiaki_holepunch_session_init("not-a-real-token", NULL) == NULL);
	ChiakiHolepunchSession sentinel = (ChiakiHolepunchSession)(uintptr_t)1;
	REQUIRE(chiaki_holepunch_session_create(sentinel) == CHIAKI_ERR_UNINITIALIZED);
	const uint8_t console_uid[32] = { 0 };
	REQUIRE(chiaki_holepunch_session_start(
		sentinel,
		console_uid,
		CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5) == CHIAKI_ERR_UNINITIALIZED);
	REQUIRE(chiaki_holepunch_upnp_discover(sentinel) == CHIAKI_ERR_UNINITIALIZED);
	REQUIRE(holepunch_session_create_offer(sentinel) == CHIAKI_ERR_UNINITIALIZED);
	REQUIRE(chiaki_holepunch_session_punch_hole(
		sentinel,
		CHIAKI_HOLEPUNCH_PORT_TYPE_CTRL) == CHIAKI_ERR_UNINITIALIZED);

	ChiakiHolepunchRegistInfo expected_info = { 0 };
	ChiakiHolepunchRegistInfo actual_info = chiaki_get_regist_info(sentinel);
	REQUIRE(memcmp(&actual_info, &expected_info, sizeof(expected_info)) == 0);
	char selected_address[9] = "sentinel";
	chiaki_get_ps_selected_addr(sentinel, selected_address);
	REQUIRE(selected_address[0] == '\0');
	REQUIRE(chiaki_get_ps_ctrl_port(sentinel) == 0);
	REQUIRE(chiaki_get_holepunch_sock(
		sentinel,
		CHIAKI_HOLEPUNCH_PORT_TYPE_DATA) == NULL);

	chiaki_holepunch_main_thread_cancel(sentinel, true);
	chiaki_holepunch_session_fini(sentinel);
	puts("LOCAL-ONLY HOLEPUNCH VERIFIED  endpoint-free fail-closed compatibility surface");
	return 0;
}
