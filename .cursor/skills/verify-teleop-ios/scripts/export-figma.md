# Exporting Figma frames (read-only)

Figma is read-only. Never edit the file. Use the Figma MCP `get_screenshot`
(fileKey `inLwADDDptRo8qIw34DRqP`, nodeId from `frames.tsv`) once per frame,
then download the returned short-lived URL to `<figma-dir>/<SCREEN_ID>.png`:

    curl -fL -o "$FIGMA_DIR/S1.png" "<image_url>"

Alternative with a personal token (never commit it):

    curl -fH "X-Figma-Token: $FIGMA_TOKEN" \
      "https://api.figma.com/v1/images/inLwADDDptRo8qIw34DRqP?ids=121:1126&format=png&scale=1"

Frames export at 402x874 (scale 1).
