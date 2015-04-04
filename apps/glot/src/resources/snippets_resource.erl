-module(snippets_resource).
-export([
    init/3,
    rest_init/2,
    allowed_methods/2,
    malformed_request/2,
    options/2,
    content_types_accepted/2,
    content_types_provided/2,
    resource_exists/2,
    allow_missing_post/2,
    list/2,
    accept_post/2
]).

-define(WRONG_TOKEN, <<"Wrong auth token">>).
-define(MAX_PER_PAGE, 100).
-define(WRONG_PAGE, <<"page must be >= 1">>).
-define(WRONG_MAX_PER_PAGE, <<"per_page must be >= 1 and <= 100">>).

-record(state, {
    user_id,
    pagination
}).

init(_Transport, _Req, _Opts) ->
    {upgrade, protocol, cowboy_rest}.

rest_init(Req, []) ->
    {ok, Req, #state{}}.

methods() ->
    [<<"OPTIONS">>, <<"GET">>, <<"POST">>].

allowed_methods(Req, State) ->
    {methods(), Req, State}.

malformed_request(Req, State) ->
    {PageNo, _} = cowboy_req:qs_val(<<"page">>, Req, <<"1">>),
    {PerPage, _} = cowboy_req:qs_val(<<"per_page">>, Req, integer_to_binary(?MAX_PER_PAGE)),
    case {binary_to_integer(PageNo), binary_to_integer(PerPage)} of
        {N, _} when (N < 1) ->
            Req2 = http_util:set_response_msg(?WRONG_PAGE, Req),
            {true, Req2, State};
        {_, N} when (N < 1 orelse N > ?MAX_PER_PAGE) ->
            Req2 = http_util:set_response_msg(?WRONG_MAX_PER_PAGE, Req),
            {true, Req2, State};
        Pagination ->
            {false, Req, State#state{pagination=Pagination}}
    end.

options(Req, State) ->
    Req2 = http_util:add_cors_headers(Req, methods()),
    Req3 = http_util:add_allow_header(Req2, methods()),
    {ok, Req3, State}.

content_types_accepted(Req, State) ->
    Handlers = [
        {{<<"application">>, <<"json">>, '*'}, accept_post}
    ],
    {Handlers, Req, State}.

content_types_provided(Req, State) ->
    Handlers = [
        {{<<"application">>, <<"json">>, '*'}, list}
    ],
    {Handlers, Req, State}.

resource_exists(Req, State) ->
    case lookup_user_id(Req) of
        {ok, UserId} ->
            {true, Req, State#state{user_id=UserId}};
        {error, not_found} ->
            Data = jsx:encode(#{message => ?WRONG_TOKEN}),
            Req2 = cowboy_req:set_resp_body(Data, Req),
            {false, Req2, State}
    end.

allow_missing_post(Req, State) ->
    {false, Req, State}.

list(Req, State=#state{user_id=UserId, pagination=Pagination}) ->
    Snippets = case UserId of
        <<"anonymous">> ->
            {Owner, _} = cowboy_req:qs_val(<<"owner">>, Req),
            list_public(Owner, Pagination);
        _ ->
            snippet:list_by_owner(UserId, Pagination)
    end,
    Req2 = http_util:add_cors_headers(Req, methods()),
    {prepare_list_response(Snippets), Req2, State}.

list_public(undefined, Pagination) ->
    snippet:list_public(Pagination);
list_public(Owner, Pagination) ->
    snippet:list_public_by_owner(Owner, Pagination).

accept_post(Req, State) ->
    http_util:decode_body(fun save_snippet/3, Req, State).

save_snippet(Data, Req, State=#state{user_id=UserId}) ->
    Snippet = snippet:save(normalize(UserId, Data)),
    Req2 = cowboy_req:set_resp_body(prepare_response(Snippet), Req),
    Req3 = http_util:add_cors_headers(Req2, methods()),
    {true, Req3, State}.

lookup_user_id(Req) ->
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        {ok, {<<"token">>, Token}, _} -> get_user_id(Token);
        _ -> {ok, <<"anonymous">>}
    end.

get_user_id(Token) ->
    case users:get_by_token(Token) of
        {ok, User} -> {ok, proplists:get_value(<<"id">>, User)};
        Error -> Error
    end.

normalize(<<"anonymous">>=UserId, Data) ->
    % Ensure that anonymous snippets are public
    NewData = [{<<"public">>, true}|proplists:delete(<<"public">>, Data)],
    normalize_foo(UserId, NewData);
normalize(UserId, Data) ->
    normalize_foo(UserId, Data).

normalize_foo(UserId, Data) ->
    Files = [normalize_file(X) || X <- proplists:get_value(<<"files">>, Data, [])],
    [
        {<<"language">>, proplists:get_value(<<"language">>, Data, <<>>)},
        {<<"title">>, proplists:get_value(<<"title">>, Data, <<"untitled">>)},
        {<<"public">>, proplists:get_value(<<"public">>, Data, false)},
        {<<"owner">>, UserId},
        {<<"files">>, Files}
    ].

normalize_file(Data) ->
    [
        {<<"name">>, proplists:get_value(<<"name">>, Data, <<"untitled">>)},
        {<<"content">>, proplists:get_value(<<"content">>, Data, <<>>)}
    ].

prepare_list_response(Snippets) ->
    NewSnippets = lists:map(fun(X) ->
        Id = proplists:get_value(<<"id">>, X),
        [{<<"url">>, get_url(Id)}|X]
    end, Snippets),
    jsx:encode(NewSnippets).

prepare_response(Snippet) ->
    Id = proplists:get_value(<<"_id">>, Snippet),
    Mutators = [
        fun(X) -> proplists:delete(<<"_id">>, X) end,
        fun(X) -> proplists:delete(<<"_rev">>, X) end,
        fun(X) -> [{<<"id">>, Id}, {<<"url">>, get_url(Id)}|X] end
    ],
    NewSnippet = lists:foldl(fun(F, Acc) -> F(Acc) end, Snippet, Mutators),
    jsx:encode(NewSnippet).

get_url(Id) ->
    BaseUrl = config:base_url(),
    <<BaseUrl/binary, "/snippets/", Id/binary>>.
