defmodule AppWeb.ImgupNoClientLive do
  use AppWeb, :live_view

  @upload_dir Application.app_dir(:app, ["priv", "static", "image_uploads"])

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:uploaded_files, [])
     |> assign(:uploaded_files_locally, [])
     |> assign(:uploaded_files_to_S3, [])
     |> allow_upload(:image_list,
       accept: ~w(image/*),
       max_entries: 6,
       chunk_size: 64_000,
       auto_upload: true,
       max_file_size: 5_000_000,
       progress: &handle_progress/3
       # Do not defined presign_upload. This will create a local photo in /vars
     )}
  end

  # With `auto_upload: true`, we can consume files here
  defp handle_progress(:image_list, entry, socket) do
    if entry.done? do
      uploaded_file =
        consume_uploaded_entry(socket, entry, fn %{path: path} = meta ->
          base = Path.basename(path)
          dest = Path.join(@upload_dir, entry.client_name)

          # Copying the file from temporary folder to static folder
          File.mkdir_p(@upload_dir)
          File.cp!(path, dest)

          entry =
            Map.put(
              entry,
              :image_url,
              AppWeb.Endpoint.url() <>
                AppWeb.Endpoint.static_path("/image_uploads/#{entry.client_name}")
            )

          entry =
            Map.put(
              entry,
              :url_path,
              AppWeb.Endpoint.static_path("/image_uploads/#{entry.client_name}")
            )

          {:ok, entry}
        end)

      {:noreply, update(socket, :uploaded_files_locally, &(&1 ++ [uploaded_file]))}
    else
      {:noreply, socket}
    end
  end

  # Event handlers -------

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("remove-selected", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :image_list, ref)}
  end

  @impl true
  def handle_event("upload_to_s3", params, socket) do

    # Get file element from the local files array
    file_element =
      Enum.find(socket.assigns.uploaded_files_locally, fn %{uuid: uuid} ->
        uuid == Map.get(params, "uuid")
      end)

    # Create file object to upload
    file = %{
      path: @upload_dir <> "/" <> Map.get(file_element, :client_name),
      content_type: file_element.client_type,
      filename: file_element.client_name
    }

    # Upload file
    case App.Upload.upload(file) do

      # If the upload succeeds...
      {:ok, body} ->

        # We add the `uuid` to the object to display on the view template.
        body = Map.put(body, :uuid, file_element.uuid)

        # Delete the file locally
        File.rm!(file.path)

        # Update the socket accordingly
        updated_local_array = List.delete(socket.assigns.uploaded_files_locally, file_element)

        socket = update(socket, :uploaded_files_to_S3, &(&1 ++ [body]))
        socket = assign(socket, :uploaded_files_locally, updated_local_array)

        {:noreply, socket}

      {:error, reason} ->
        dbg(:error, reason)
        {:noreply, socket}
    end
  end

  # View utilities -------

  def are_files_uploadable?(local_files_list) do
    not Enum.empty?(local_files_list)
  end

  def error_to_string(:too_large), do: "Too large."
  def error_to_string(:not_accepted), do: "You have selected an unacceptable file type."
  # coveralls-ignore-start
  def error_to_string(:external_client_failure),
    do: "Couldn't upload files to S3. Open an issue on Github and contact the repo owner."

  # coveralls-ignore-stop
end
