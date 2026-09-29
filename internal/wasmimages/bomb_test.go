package wasmimages

import (
	"bytes"
	"encoding/binary"
	"hash/crc32"
)

// bombPNGHeader builds a byte-tiny PNG carrying only the signature and a valid
// IHDR chunk that DECLARES w×h pixels. image.DecodeConfig reads exactly this
// much, so it is the honest fixture for "the header claims a decompression
// bomb" — the case a byte-size cap alone cannot catch.
func bombPNGHeader(w, h uint32) []byte {
	var out bytes.Buffer
	out.WriteString("\x89PNG\r\n\x1a\n")

	var data bytes.Buffer
	binary.Write(&data, binary.BigEndian, w)
	binary.Write(&data, binary.BigEndian, h)
	data.Write([]byte{8, 2, 0, 0, 0}) // bit depth 8, truecolor, no interlace

	binary.Write(&out, binary.BigEndian, uint32(data.Len()))
	chunk := append([]byte("IHDR"), data.Bytes()...)
	out.Write(chunk)
	binary.Write(&out, binary.BigEndian, crc32.ChecksumIEEE(chunk))
	return out.Bytes()
}
