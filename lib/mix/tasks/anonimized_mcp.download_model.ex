defmodule Mix.Tasks.AnonimizedMcp.DownloadModel do
  @shortdoc "Downloads the NER model into the cache directory"
  @moduledoc """
  Downloads the NER model (`AnonimizedMcp.Masking.Ner`) into the user cache
  directory, so a container image ships it and the server starts without
  network access to Hugging Face.

      mix anonimized_mcp.download_model
  """

  use Mix.Task

  @requirements ["compile"]

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:req)
    Mix.shell().info("Model in #{AnonimizedMcp.Masking.Ner.download!()}")
  end
end
