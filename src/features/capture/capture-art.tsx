export function CaptureArt() {
  return (
    <svg
      className="capture-art"
      viewBox="0 0 384 196"
      fill="none"
      shapeRendering="crispEdges"
      aria-hidden="true"
      focusable="false"
    >
      {/* Sparse stars frame the window without cross-shaped sparkles. */}
      <g fill="#111111">
        <path d="M64 60h4v4h-4zM152 24h4v4h-4zM324 100h4v4h-4zM172 164h4v4h-4z" />
        <path d="M44 112h2v2h-2zM276 28h2v2h-2zM316 172h2v2h-2z" />
        <path d="M308 48h4v4h4v8h-4v4h-4v-4h-4v-8h4z" />
      </g>
      {/* A tiny stepped crescent adds a quiet space cue. */}
      <g transform="translate(64 132)">
        <path
          fill="#111111"
          d="M8 0h12v4h8v8h4v8h-4v8h-8v4H8v-4H0v-8h-4v-8h4V4h8z"
        />
        <path fill="#ffffff" d="M16 0h4v4h8v8h4v8h-8v4H12v-4H4V8h4V4h8z" />
      </g>
      {/* One app window, with a stepped outline and quiet title-bar controls. */}
      <path fill="#111111" d="M108 44h148v4h4v88h-4v4H108v-4h-4V48h4z" />
      <path fill="#ffffff" d="M108 48h148v88H108z" />
      <g fill="#111111">
        <path d="M108 64h148v4H108zM116 52h4v4h-4zM128 52h4v4h-4zM140 52h4v4h-4z" />
        {/* A little content makes this recognizable as an app rather than a frame. */}
        <path d="M128 84h28v28h-28zM172 84h64v4h-64zM172 96h44v4h-44zM172 108h52v4h-52z" />
      </g>
      <path fill="#ffffff" d="M132 88h20v20h-20z" />
      {/* A solid recording badge overlaps the window's lower-right edge. */}
      <path
        fill="#111111"
        stroke="#ffffff"
        strokeWidth="8"
        paintOrder="stroke"
        d="M220 120h72v4h4v24h-4v4h-72v-4h-4v-24h4z"
      />
      <path fill="#ffffff" d="M232 128h8v4h4v8h-4v4h-8v-4h-4v-8h4z" />
      {/* REC lettering uses square pixels, matching the rest of the illustration. */}
      <g transform="translate(252 132) scale(2)" fill="#ffffff">
        <path d="M0 0h3v1H1v1h2v1H1v2H0zM3 1h1v1H3zM2 3h1v1H2zM3 4h1v1H3z" />
        <path d="M6 0h3v1H7v1h2v1H7v1h2v1H6z" />
        <path d="M12 0h3v1h-3zM11 1h1v3h-1zM12 4h3v1h-3z" />
      </g>
    </svg>
  );
}
