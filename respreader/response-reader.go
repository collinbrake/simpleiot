package respreader

import (
	"errors"
	"io"
	"time"
)

// ErrorTimeout indicates the reader timed out
var ErrorTimeout = errors.New("timeout")

// ResponseReadWriteCloser is a convenience type that implements io.ReadWriteCloser.
// Write calls flush reader before writing the prompt.
type ResponseReadWriteCloser struct {
	closer io.Closer
	writer io.Writer
	reader *ResponseReader
}

// NewResponseReadWriteCloser creates a new response reader
//
// timeout is used to specify an
// overall timeout. If this timeout is encountered, ErrorTimeout is returned.
//
// chunkTimeout is used to specify the max timeout between chunks of data once
// the response is started. If a delay of chunkTimeout is encountered, the response
// is considered finished and the Read returns.
func NewResponseReadWriteCloser(iorw io.ReadWriteCloser, timeout time.Duration, chunkTimeout time.Duration) *ResponseReadWriteCloser {
	return &ResponseReadWriteCloser{
		closer: iorw,
		writer: iorw,
		reader: NewResponseReader(iorw, timeout, chunkTimeout),
	}
}

// Read response using chunkTimeout and timeout
func (rrwc *ResponseReadWriteCloser) Read(buffer []byte) (int, error) {
	return rrwc.reader.Read(buffer)
}

// Write flushes all data from reader, and then passes through write call.
func (rrwc *ResponseReadWriteCloser) Write(buffer []byte) (int, error) {
	n, err := rrwc.reader.Flush()
	if err != nil {
		return n, err
	}

	return rrwc.writer.Write(buffer)
}

// Close is a passthrough call.
func (rrwc *ResponseReadWriteCloser) Close() error {
	rrwc.reader.closed = true
	return rrwc.closer.Close()
}

// ResponseReadCloser is a convenience type that implements io.ReadWriter. Write
// calls flush reader before writing the prompt.
type ResponseReadCloser struct {
	closer io.Closer
	reader *ResponseReader
}

// NewResponseReadCloser creates a new response reader
//
// timeout is used to specify an
// overall timeout. If this timeout is encountered, ErrorTimeout is returned.
//
// chunkTimeout is used to specify the max timeout between chunks of data once
// the response is started. If a delay of chunkTimeout is encountered, the response
// is considered finished and the Read returns.
func NewResponseReadCloser(iorw io.ReadCloser, timeout time.Duration, chunkTimeout time.Duration) *ResponseReadCloser {
	return &ResponseReadCloser{
		closer: iorw,
		reader: NewResponseReader(iorw, timeout, chunkTimeout),
	}
}

// Read response using chunkTimeout and timeout
func (rrwc *ResponseReadCloser) Read(buffer []byte) (int, error) {
	return rrwc.reader.Read(buffer)
}

// Close is a passthrough call.
func (rrwc *ResponseReadCloser) Close() error {
	rrwc.reader.closed = true
	return rrwc.closer.Close()
}

// ResponseReadWriter is a convenience type that implements io.ReadWriter. Write
// calls flush reader before writing the prompt.
type ResponseReadWriter struct {
	writer io.Writer
	reader *ResponseReader
}

// NewResponseReadWriter creates a new response reader
func NewResponseReadWriter(iorw io.ReadWriter, timeout time.Duration, chunkTimeout time.Duration) *ResponseReadWriter {
	return &ResponseReadWriter{
		writer: iorw,
		reader: NewResponseReader(iorw, timeout, chunkTimeout),
	}
}

// Read response
func (rrw *ResponseReadWriter) Read(buffer []byte) (int, error) {
	return rrw.reader.Read(buffer)
}

// Write flushes all data from reader, and then passes through write call.
func (rrw *ResponseReadWriter) Write(buffer []byte) (int, error) {
	n, err := rrw.reader.Flush()
	if err != nil {
		return n, err
	}

	return rrw.writer.Write(buffer)
}

// ResponseReader is used for prompt/response communication protocols where a prompt
// is sent, and some time later a response is received. Typically, the target takes
// some amount to formulate the response, and then streams it out. There are two delays:
// an overall timeout, and then an inter character timeout that is activated once the
// first byte is received. The thought is that once you received the 1st byte, all the
// data should stream out continuously and a short timeout can be used to determine the
// end of the packet.
type ResponseReader struct {
	reader       io.Reader
	timeout      time.Duration
	chunkTimeout time.Duration
	size         int
	dataChan     chan []byte
	closed       bool
}

// NewResponseReader creates a new response reader.
//
// timeout is used to specify an
// overall timeout. If this timeout is encountered, ErrorTimeout is returned.
//
// chunkTimeout is used to specify the max timeout between chunks of data once
// the response is started. If a delay of chunkTimeout is encountered, the response
// is considered finished and the Read returns.
func NewResponseReader(reader io.Reader, timeout time.Duration, chunkTimeout time.Duration) *ResponseReader {
	rr := ResponseReader{
		reader:       reader,
		timeout:      timeout,
		chunkTimeout: chunkTimeout,
		size:         128,
		dataChan:     make(chan []byte),
	}
	// we have to start a reader goroutine here that lives for the life
	// of the reader because there is no
	// way to stop a blocked goroutine
	go rr.readInput()
	return &rr
}

// Read response
func (rr *ResponseReader) Read(buffer []byte) (int, error) {
	if len(buffer) <= 0 {
		return 0, errors.New("must supply non-zero length buffer")
	}

	timeout := time.NewTimer(rr.timeout)
	count := 0

	for {
		select {
		case newData, ok := <-rr.dataChan:
			// copy data from chan buffer to Read() buf
			for i := 0; count < len(buffer) && i < len(newData); i++ {
				buffer[count] = newData[i]
				count++
			}

			if !ok {
				return count, io.EOF
			}

			timeout.Reset(rr.chunkTimeout)

		case <-timeout.C:
			if count > 0 {
				return count, nil
			}

			return count, ErrorTimeout

		}
	}
}

// Flush is used to flush any input data
func (rr *ResponseReader) Flush() (int, error) {
	timeout := time.NewTimer(rr.chunkTimeout)
	count := 0

	for {
		select {
		case newData, ok := <-rr.dataChan:
			count += len(newData)
			if !ok {
				return count, io.EOF
			}

			timeout.Reset(rr.chunkTimeout)

		case <-timeout.C:
			return count, nil
		}
	}
}

// readInput is used by a goroutine to read data from the underlying io.Reader
func (rr *ResponseReader) readInput() {
	for {
		tmp := make([]byte, rr.size)
		if rr.closed {
			break
		}
		length, _ := rr.reader.Read(tmp)
		if length > 0 {
			tmp = tmp[0:length]
			rr.dataChan <- tmp
		}
	}
	close(rr.dataChan)
}
