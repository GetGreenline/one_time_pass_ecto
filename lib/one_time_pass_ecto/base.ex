defmodule OneTimePassEcto.Base do
  @moduledoc """
  Generate and verify HOTP and TOTP one-time passwords.

  Module to generate and check HMAC-based one-time passwords and
  time-based one-time passwords, in accordance with
  [RFC 4226](https://tools.ietf.org/html/rfc4226) and
  [RFC 6238](https://tools.ietf.org/html/rfc6238).

  ## Two factor authentication

  These one-time passwords are often used together with regular passwords
  to provide two factor authentication (2FA), which forms a layered approach
  to user authentication. The advantage of 2FA over just using passwords is
  that an attacker would face an additional challenge to being authorized.
  """

  import Bitwise

  @doc """
  Generate a secret key to be used with one-time passwords.

  By default, this function creates a 16 character base32 (80-bit)
  string, which is compatible with Google Authenticator.

  It is also possible to generate 26 character (128-bit) and
  32 character (160-bit) secret keys.

  ## RFC 4226 secret key length recommendations

  According to RFC 4226, the secret key length must be at least
  128 bits long, and the recommended length is 160 bits.
  """
  def gen_secret(secret_length \\ 16)

  def gen_secret(secret_length) when secret_length in [16, 26, 32, 64] do
    trunc(secret_length / 1.6)
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(padding: false)
  end

  def gen_secret(_), do: raise(ArgumentError, "Invalid length")

  @doc """
  Check the one-time password is valid.

  The one-time password should be at least 6 characters long, and it
  should be a string which only contains numeric values.
  """
  def valid_token(token, _) when not is_binary(token) do
    raise ArgumentError, "The token should be a string"
  end

  def valid_token(token, token_length)
      when token_length >= 6 and token_length == byte_size(token) do
    Regex.match?(~r/^[0-9]+$/, token)
  end

  def valid_token(_, _), do: false

  @doc """
  Generate a HMAC-based one-time password.

  Note that the `count` (2nd argument) should be a positive integer.

  There is one option:

    * `:token_length` - the length of the one-time password
      * the default is 6
  """
  def gen_hotp(secret, count, opts \\ []) do
    token_length = Keyword.get(opts, :token_length, 6)

    hash =
      hmac(
        :sha,
        Base.decode32!(secret, padding: false),
        <<count::size(8)-big-unsigned-integer-unit(8)>>
      )

    offset = :binary.at(hash, 19) &&& 15
    <<truncated::size(4)-integer-unit(8)>> = :binary.part(hash, offset, 4)

    (truncated &&& 0x7FFFFFFF)
    |> rem(trunc(:math.pow(10, token_length)))
    |> :erlang.integer_to_binary()
    |> String.pad_leading(token_length, "0")
  end

  @doc """
  Generate a time-based one-time password.

  There are two options:

    * `:token_length` - the length of the one-time password
      * the default is 6
    * `:interval_length` - the length of each timed interval
      * the default is 30 (seconds)
  """
  def gen_totp(secret, opts \\ []) do
    gen_hotp(secret, Keyword.get(opts, :interval_length, 30) |> interval_count, opts)
  end

  @doc """
  Verify a HMAC-based one-time password.

  There are three options:

    * `:token_length` - the length of the one-time password
      * the default is 6
    * `:last` - the count when the one-time password was last used
      * this count needs to be stored server-side
    * `:window` - the number of future attempts allowed
      * the default is 3
  """
  def check_hotp(token, secret, opts \\ []) do
    valid_token(token, Keyword.get(opts, :token_length, 6)) and
      (
        {last, window} = {Keyword.get(opts, :last, 0), Keyword.get(opts, :window, 3)}
        check_token(token, secret, last + 1, last + window + 1, opts)
      )
  end

  @doc """
  Verify a time-based one-time password.

  There are three options:

    * `:token_length` - the length of the one-time password
      * the default is 6
    * `:interval_length` - the length of each timed interval
      * the default is 30 (seconds)
    * `:window` - the number of attempts, before and after the current one, allowed
      * the default is 1 (1 interval before and 1 interval after)
      * you might need to increase this window to allow for clock skew on the server
  """
  def check_totp(token, secret, opts \\ []) do
    valid_token(token, Keyword.get(opts, :token_length, 6)) and
      (
        {count, window} =
          {
            Keyword.get(opts, :interval_length, 30) |> interval_count,
            Keyword.get(opts, :window, 1)
          }

        check_token(token, secret, count - window, count + window, opts)
      )
  end

  defp interval_count(interval_length) do
    trunc(System.system_time(:second) / interval_length)
  end

  defp check_token(_token, _secret, current, last, _opts) when current > last do
    false
  end

  defp check_token(token, secret, current, last, opts) do
    case gen_hotp(secret, current, opts) do
      ^token -> current
      _ -> check_token(token, secret, current + 1, last, opts)
    end
  end

  # TODO: remove when the Elixir version requires OTP 22
  if System.otp_release() >= "22" do
    defp hmac(digest, key, data), do: :crypto.mac(:hmac, digest, key, data)
  else
    defp hmac(digest, key, data), do: :crypto.hmac(digest, key, data)
  end
end
