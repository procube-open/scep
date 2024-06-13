import * as React from 'react';
import {
  useNotify,
  useTranslate,
  useRefresh,
} from 'react-admin';
import {
  Button,
  Box,
  Typography,
} from '@mui/material';
import { FaFileDownload } from "react-icons/fa";
import CircularProgress, {
  CircularProgressProps,
} from '@mui/material/CircularProgress';
import LinearProgress, {
  LinearProgressProps
} from '@mui/material/LinearProgress';

function download(blob: Blob, filename: string) {
  const url = window.URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.style.display = 'none';
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  window.URL.revokeObjectURL(url);
}

function LinearProgressWithLabel(props: LinearProgressProps & { value: number }) {
  return (
    <Box sx={{ display: 'flex', alignItems: 'center', width: 1 }}>
      <Box sx={{ width: '100%', mr: 1 }}>
        <LinearProgress variant="determinate" {...props} />
      </Box>
      <Box sx={{ minWidth: 35 }}>
        <Typography variant="body2" color="text.secondary">
          {`${Math.round(props.value,)}%`}
        </Typography>
      </Box>
    </Box>
  );
}

function CircularProgressWithLabel(
  props: CircularProgressProps & { value: number },
) {
  return (
    <Box sx={{ position: 'relative', display: 'inline-flex' }}>
      <CircularProgress variant="determinate" {...props} />
      <Box
        sx={{
          top: 20,
          left: 0,
          bottom: 0,
          right: 0,
          position: 'absolute',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
        }}
      >
        <Typography
          variant="caption"
          component="div"
          color="text.secondary"
        >
          {`${Math.round(props.value)}%`}
        </Typography>
      </Box>
    </Box>
  );
}

const DownloadButton = (props: { downloadProvider: any, filename: string, sx: any, color: any, isLinear: boolean, disabled: boolean, type: "button" | "reset" | "submit" | undefined, children?: any }) => {
  const { downloadProvider, filename, sx, color, children, isLinear, type, disabled } = props
  const notify = useNotify();
  const refresh = useRefresh();
  const [state, setState] = React.useState(false)
  const [progress, setProgress] = React.useState(0)
  const [total, setTotal] = React.useState(1)
  const handler = (response: Response) => new Promise((resolve, reject) => {
    const contentLength = response.headers.get('content-length');
    if (contentLength === null) return notify('error.contentLengthError', { type: 'error' })
    setTotal(parseInt(contentLength, 10))
    const res = new Response(new ReadableStream({
      async start(controller) {
        if (response.body === null) return notify('error.bodyError', { type: 'error' })
        const reader = response.body.getReader();
        while (true) {
          const { done, value } = await reader.read();
          if (done) {
            break
          }
          setProgress(progress => progress + value.byteLength)
          controller.enqueue(value);
        }
        controller.close();
      },
    }));
    return res.blob().then((blob: Blob) => download(blob, filename)).then(resolve).catch(reject);
  })
  if (state) {
    const percent = total > 0 ? Math.floor((progress / total) * 100) : 100
    return <Button size="small" disabled sx={sx}>
      {
        isLinear ?
          <LinearProgressWithLabel value={percent} sx={{ mr: 1, mt: -1 }} color={color} /> :
          <CircularProgressWithLabel size={20} value={percent} sx={{ mr: 1, mt: -1 }} color={color} />
      }
    </Button>
  }
  else {
    return (<Button
      color={color}
      sx={sx}
      type={type}
      disabled={disabled}
      startIcon={< FaFileDownload />}
      children={children && children}
      onClick={() => {
        notify(`file.downloading`, { type: 'info', messageArgs: { filename: filename } })
        setState(true)
        downloadProvider().then(async (response: Response) => {
          if (!response.ok) {
            const json = await response.json()
            throw new Error(json.message)
          }
          else return handler(response)
        }).then(() => {
          notify(`file.downloaded`, { type: 'success', messageArgs: { filename: filename } })
        }).catch((error: Error) => {
          notify(error.message, { type: 'error' })
        }).finally(() => {
          setTimeout(() => {
            setState(false)
            setProgress(0)
            refresh()
          }, 1500);
        })
      }}
    />)
  }

};
export default DownloadButton