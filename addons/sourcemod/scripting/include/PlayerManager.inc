#if defined _PlayerManager_included
	#endinput
#endif

#define _PlayerManager_included

/**
 * Check if clients usertype is legit.
 *
 * @param client            The client index.
 *
 * @return                  True if legit, false otherwise.
 * @error                   Invalid client index, not connected or fake client.
 */
native bool PM_IsPlayerSteam(int client);

/**
 * Retrieve clients usertype.
 *
 * @param client            The client index.
 * @param type              The integer to write to (1 = Steam, 0 = NoSteam).
 *
 * @return                  True on success, false otherwise.
 * @error                   Invalid client index, not connected or fake client.
 */
native bool PM_GetPlayerType(int client, int type);

/**
 * Retrieve clients globally unique identifier (GUID).
 *
 * @param client            The client index.
 *
 * @return                  GUID on success, -1 otherwise.
 * @error                   Invalid client index, not connected or fake client.
 */
native int PM_GetPlayerGUID(int client);


public SharedPlugin __pl_PlayerManager =
{
	name = "PlayerManager",
	file = "PlayerManager.smx",

	#if defined REQUIRE_PLUGIN
		required = 1
	#else
		required = 0
	#endif
};

#if !defined REQUIRE_PLUGIN
	public void __pl_PlayerManager_SetNTVOptional()
	{
		MarkNativeAsOptional("PM_IsPlayerSteam");
		MarkNativeAsOptional("PM_GetPlayerType");
		MarkNativeAsOptional("PM_GetPlayerGUID");
	}
#endif
