#!/bin/sh
# Waits for MPC to start, then logs (for 40 s) every IOKit user-client call it makes with its arguments, to /tmp/mpc-iokit.txt.
echo "Enter your Mac password, then start MPC when it says 'waiting for MPC'."
sudo -v || exit 1
echo "waiting for MPC..."
sudo dtrace -Z -q -W MPC -o /tmp/mpc-iokit.txt -n '
BEGIN { start = timestamp; }
pid$target:IOKit:IOConnectCallMethod:entry {
  printf("%d.%03d CALL conn=%x sel=%d nScalar=%d nStruct=%d\n", (timestamp-start)/1000000000, ((timestamp-start)/1000000)%1000, arg0, arg1, arg3, arg5);
  this->n = arg3 > 16 ? 16 : arg3;
  if (this->n > 0) { tracemem(copyin(arg2, 128), 128, this->n * 8); }
  if (arg5 > 0 && arg5 <= 256) { tracemem(copyin(arg4, 256), 256, arg5); }
}
pid$target:IOKit:IOConnectCallAsyncMethod:entry {
  printf("%d.%03d ASYNC conn=%x sel=%d nScalar=%d nStruct=%d\n", (timestamp-start)/1000000000, ((timestamp-start)/1000000)%1000, arg0, arg1, arg6, arg8);
  this->m = arg6 > 16 ? 16 : arg6;
  if (this->m > 0) { tracemem(copyin(arg5, 128), 128, this->m * 8); }
  if (arg8 > 0 && arg8 <= 256) { tracemem(copyin(arg7, 256), 256, arg8); }
}
tick-1s /timestamp - start > 40000000000/ { exit(0); }'
echo "Done — log in /tmp/mpc-iokit.txt"
