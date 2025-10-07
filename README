# Erlang Non-Blocking Channel Broadcast

This Erlang module snippet demonstrates how to broadcast a message to all users in a channel **without blocking the channel process**, even when the number of users is very large.

---

## channel_handler/2

```erlang
channel_handler(State, {message_send, Nick, Msg, SenderId}) ->
    Users = maps:get("users", State, #{}),
    case maps:is_key(SenderId, Users) of
        true ->
            ChanName = maps:get("name", State),
            % Collect all PIDs except the sender
            Pids = [P || {Id, P} <- maps:to_list(Users), Id =/= SenderId],
            % Spawn a separate process to handle the broadcast
            spawn(fun() -> broadcast(Pids, ChanName, Nick, Msg) end),
            {reply, ok, State};
        false ->
            {reply, user_not_joined, State}
    end.
```

**Explanation:**

* Checks if the sender is a valid user.
* Collects all user PIDs except the sender.
* Spawns a separate process to send messages, so the channel process returns immediately.

---

## broadcast/4

```erlang
broadcast([], _Chan, _Nick, _Msg) ->
    ok;
broadcast(Pids, Chan, Nick, Msg) ->
    lists:foreach(
        fun(Pid) ->
            spawn(fun() -> send_message(Chan, Nick, Msg, Pid) end)
        end,
        Pids
    ).
```

**Explanation:**

* Iterates over all PIDs and spawns a lightweight process for each `send_message/4`.
* This ensures sending is **concurrent** and **non-blocking**.

---

## send_message/4

```erlang
send_message(Channel, Nick, Msg, Pid) ->
    Ref = make_ref(),
    Pid ! {request, self(), Ref, {message_receive, Channel, Nick, Msg}}.
```

**Explanation:**

* Sends the message to a single PID.
* Keeps the original message format intact.

---

### Key Benefits:

1. Non-blocking channel process: The channel immediately replies, even if there are millions of users.
2. Concurrent sending: Each message is sent in a separate process to avoid slow receivers blocking others.
3. Scalable: Suitable for large channels without performance degradation.

---