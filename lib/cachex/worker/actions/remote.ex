defmodule Cachex.Worker.Actions.Remote do
  @moduledoc false
  # This module defines the Remote actions a worker can take. Functions in this
  # module are focused around the sole use of Mnesia in order to provide needed
  # replication. These calls do not handle row locking and as such they're a
  # middle ground (in terms of performance) between the Local actions and the
  # Transactional actions. Many functions in here delegate to the Transactional
  # actions due to consistency assurances.

  # add some aliases
  alias Cachex.Util
  alias Cachex.Worker.Actions

  @doc """
  Simply do an Mnesia dirty read on the given key. If the key does not exist we
  check to see if there's a fallback function. If there is we call it and then
  set the value into the cache before returning it to the user. Otherwise we
  simply return a nil value in an ok tuple.
  """
  def get(state, key, options) do
    fb_fun =
      options
      |> Util.get_opt_function(:fallback)

    val = case :mnesia.dirty_read(state.cache, key) do
      [{ _cache, ^key, touched, ttl, value }] ->
        case Util.has_expired?(touched, ttl) do
          true  -> Actions.del(state, key); :missing;
          false -> value
        end
      _unrecognised_val -> :missing
    end

    case val do
      :missing ->
        { status, new_value } =
          result =
            state
            |> Util.get_fallback(key, fb_fun)

        state
        |> Actions.set(key, new_value)

        case status do
          :ok -> { :missing, new_value }
          :loaded -> result
        end
      val ->
        { :ok, val }
    end
  end

  @doc """
  Inserts a value into the Mnesia tables, without caring about overwrites. We
  transform the result into an ok/error tuple to keep consistency in the API.
  """
  def set(state, key, value, options) do
    ttl =
      options
      |> Util.get_opt_number(:ttl)

    state
    |> Util.create_record(key, value, ttl)
    |> :mnesia.dirty_write
    |> (&(Util.create_truthy_result(&1 == :ok))).()
  end

  @doc """
  We delegate to the Transactional actions as this function requires both a
  get/set, and as such it's only safe to do via a transaction.
  """
  defdelegate update(state, key, value, options),
  to: Cachex.Worker.Actions.Transactional

  @doc """
  Removes a record from the cache using the provided key. Regardless of whether
  the key exists or not, we return a truthy value (to signify the record is not
  in the cache).
  """
  def del(state, key, _options) do
    state.cache
    |> :mnesia.dirty_delete(key)
    |> (&(Util.create_truthy_result(&1 == :ok))).()
  end

  @doc """
  Empties the cache entirely of keys. We delegate to the Transactional actions
  as the behaviour matches between implementations.
  """
  defdelegate clear(state, options),
  to: Cachex.Worker.Actions.Transactional

  @doc """
  Sets the expiration time on a given key based on the value passed in. We pass
  this through to the Transactional actions as we require a get/set combination.
  """
  defdelegate expire(state, key, expiration, options),
  to: Cachex.Worker.Actions.Transactional

  @doc """
  Uses a select internally to fetch all the keys in the underlying Mnesia table.
  We use a fast select to determine that we only pull keys back which are not
  already expired.
  """
  def keys(state, _options) do
    state.cache
    |> :mnesia.dirty_select(Util.retrieve_all_rows(:"$1"))
    |> Util.ok
  end

  @doc """
  We delegate to the Transactional actions as this function requires both a
  get/set, and as such it's only safe to do via a transaction.
  """
  defdelegate incr(state, key, options),
  to: Cachex.Worker.Actions.Transactional

  @doc """
  Refreshes the internal timestamp on the record to ensure that the TTL only takes
  place from this point forward. We pass this through to the Transactional actions
  as we require a get/set combination.
  """
  defdelegate refresh(state, key, options),
  to: Cachex.Worker.Actions.Transactional

  @doc """
  This is like `del/2` but it returns the last known value of the key as it
  existed in the cache upon deletion. We delegate to the Transactional actions
  as this requires a potential get/del combination.
  """
  defdelegate take(state, key, options),
  to: Cachex.Worker.Actions.Transactional

  @doc """
  Checks the remaining TTL on a provided key. We do this by retrieving the local
  record and pulling out the touched and ttl fields. In order to calculate the
  remaining time, we simply subtract the sum of these numbers from the current
  time in milliseconds. We return the remaining time to live in an ok tuple. If
  the key does not exist in the cache, we return an error tuple with a warning.
  """
  def ttl(state, key, _options) do
    case :mnesia.dirty_read(state.cache, key) do
      [{ _cache, ^key, touched, ttl, _value }] ->
        case Util.has_expired?(touched, ttl) do
          true  ->
            Actions.del(state, key)
            { :missing, nil }
          false ->
            case ttl do
              nil -> { :ok, nil }
              val -> { :ok, touched + val - Util.now() }
            end
        end
      _unrecognised_val ->
        { :missing, nil }
    end
  end

end
