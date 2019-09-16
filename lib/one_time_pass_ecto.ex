defmodule OneTimePassEcto do
  @moduledoc """
  Module to handle one-time passwords, usually for use in two factor
  authentication.

  ## One-time password options

  There are the following options for the one-time passwords:

    * HMAC-based one-time passwords
      * `:token_length` - the length of the one-time password
        * the default is 6
      * `:last` - the count when the one-time password was last used
        * this count needs to be stored server-side
      * `:window` - the number of future attempts allowed
        * the default is 3
    * Time-based one-time passwords
      * `:token_length` - the length of the one-time password
        * the default is 6
      * `:interval_length` - the length of each timed interval
        * the default is 30 (seconds)
      * `:window` - the number of attempts, before and after the current one, allowed
        * the default is 1 (1 interval before and 1 interval after)

  See the documentation for the OneTimePassEcto.Base module for more details
  about generating and verifying one-time passwords.

  ## Implementation details

  The following notes provide details about how this module implements
  the verification of one-time passwords.

  It is important not to allow the one-time password to be reused within
  the timeframe that it is valid.

  For TOTPs, one method of preventing reuse is to compare the output of
  check_totp (the `last` value) with the previous output. The output
  should be greater than the previous `last` value.

  In the case of HOTPs, it is important that the database is locked
  from the time the `last` value is checked until the `last` value is
  updated.
  """

  import Ecto.{Changeset, Query}
  alias OneTimePassEcto.Base

  @doc """
  Check the one-time password, and return {:ok, user} if the one-time
  password is correct or {:error, message} if there is an error.

  After this function has been called, you need to either add the user
  to the session, by running `put_session(conn, :user_id, id)`, or send
  an API token to the user.

  See the `One-time password options` in this module's documentation
  for available options to be used as the second argument to this
  function.
  """
  def verify(params, repo, user_schema, opts \\ [])

  def verify(%{"id" => id, "hotp" => hotp}, repo, user_schema, opts) do
    {:ok, result} =
      repo.transaction(fn ->
        get_user_with_lock(repo, user_schema, id)
        |> check_hotp(hotp, opts)
        |> update_otp(repo, opts)
      end)

    result
  end

  def verify(%{"id" => id, "totp" => totp}, repo, user_schema, opts) do
    repo.get(user_schema, id)
    |> check_totp(totp, opts)
    |> update_otp(repo, opts)
  end

  defp check_hotp(user, hotp, opts) do
    otp_secret = Map.get(user, opts[:otp_secret] || :otp_secret)
    otp_last = Map.get(user, opts[:otp_last] || :otp_last)
    
    {user, Base.check_hotp(hotp, otp_secret, [last: otp_last] ++ opts)}
  end

  defp check_totp(user, totp, opts) do
    otp_secret = Map.get(user, opts[:otp_secret] || :otp_secret)
    
    {user, Base.check_totp(totp, otp_secret, opts)}
  end

  defp get_user_with_lock(repo, user_schema, id) do
    from(u in user_schema, where: u.id == ^id, lock: "FOR UPDATE")
    |> repo.one!
  end

  defp update_otp({_, false}, _, _), do: {:error, "invalid one-time password"}

  defp update_otp({user, last}, repo, opts) do
    otp_last_name = opts[:otp_last] || :otp_last
    otp_last = Map.get(user, otp_last_name)
    
    if last > otp_last do
      change(user, %{otp_last_name => last}) |> repo.update
    else
      {:error, "invalid user-identifier"}
    end
  end

end
