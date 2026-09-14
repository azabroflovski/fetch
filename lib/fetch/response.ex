defmodule Fetch.Response do
  @moduledoc """
  An HTTP response.

  Header names are lowercase. Order and duplicate headers are preserved, so
  `headers` is a list, not a map: `set-cookie` for example is commonly sent
  several times.
  """

  @enforce_keys [:status]
  defstruct status: nil, headers: [], body: ""

  @type t :: %__MODULE__{
          status: 100..599,
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @doc """
  Returns all values of a header, in the order they were received.

      iex> response = %Fetch.Response{status: 200, headers: [{"set-cookie", "a=1"}, {"set-cookie", "b=2"}]}
      iex> Fetch.Response.get_header(response, "Set-Cookie")
      ["a=1", "b=2"]
  """
  @spec get_header(t(), String.t()) :: [String.t()]
  def get_header(%__MODULE__{headers: headers}, name) do
    name = String.downcase(name, :ascii)
    for {^name, value} <- headers, do: value
  end
end
