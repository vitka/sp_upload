# sp_upload.sh

Upload files to a specified SharePoint drive using the Microsoft Graph API.

## Usage

```bash
./sp_upload.sh <file_path> [<file_path> ...]
```

## Configuration

The script is configured through the following environment variables:

- `MS_GRAPH_CLIENT_ID`: The Client ID of your Entra ID application.
- `MS_GRAPH_CLIENT_SECRET`: The Client Secret of your Entra ID application.
- `MS_GRAPH_TENANT_ID`: The Tenant ID of your Entra ID.
- `MS_GRAPH_DOMAIN`: The SharePoint domain (e.g., `your-tenant.sharepoint.com`).
- `MS_GRAPH_SITE`: The name of the SharePoint site.
- `MS_GRAPH_DRIVE`: The name of the document library (drive). Defaults to `Documents`.
- `MS_GRAPH_FOLDER`: The destination folder within the drive.

## Dependencies

This script requires the following tools to be installed:

- `curl`
- `jq`
- `head`
- `stat`
- `tail`
