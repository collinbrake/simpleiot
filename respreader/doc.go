/*
Package respreader provides a convenient way to frame response data from devices
that use
prompt/response protocols such as Modbus, other RS485 protocols, and modem
AT commands. The fundamental assumption is a device takes some variable amount of
time to respond to a prompt, formats up a response, and then streams it out the
serial port. Once the response data starts streaming, any significant gap in the
response with
no data indicates the response is complete. A Read() blocks until it detects this
"gap" or the overall timeout is reached, and then returns with accumulated data.

This method of framing a response has the following advantages:

1) minimizes the wasted timing waiting for a response to the chunkTimeout defined
below. More simplistic implementations often take the worst case response time
for all packets and simply wait that amount of time for the response to arrive.
This works, but the bus is tied up during this worst case wait that could be used for
sending the next packet.

2) It is simple in that you don't have to parse the response on the fly to determine
when it is complete, yet it can detect the end of a response fairly quickly.

The obvious disadvantage of this method of framing is that the device may insert a
significant delay in sending the response that will cause the reader to think the
response is complete. As long as this delay is still significantly shorter than
the overall response time, it can still work fairly well. Some experimentation may
be required to optimize the chunkTimeout setting.

Example using a serial port:

	import (
		"io"

		"github.com/jacobsa/go-serial/serial"
		"github.com/simpleiot/simpleiot/respreader"
	)

	options := serial.OpenOptions{
		PortName:              "/dev/ttyUSB0",
		BaudRate:              9600,
		DataBits:              8,
		StopBits:              1,
		MinimumReadSize:       1,
		InterCharacterTimeout: 0,
		RTSCTSFlowControl:     true,
	}

	port, err := serial.Open(options)

	port = respreader.NewResponseReadWriteCloser(port, time.Second,
	time.Millisecond * 50)

	// send out prompt
	port.Write("ATAI")

	// read response
	data := make([]byte, 128)
	count, err := port.Read(data)
	data = data[0:count]

	// now process response ...


Three types are provided for convenience that wrap io.Reader, io.ReadWriter, and io.ReadWriteCloser.
*/
package respreader