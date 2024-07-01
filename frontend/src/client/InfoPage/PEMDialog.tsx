import {
  Button,
  Dialog,
  DialogActions,
  DialogContent,
  DialogTitle,
  IconButton,
  Typography,
} from '@mui/material';
import { FaCopy } from "react-icons/fa";
import { IoIosClose } from "react-icons/io";
import { useNotify, useTranslate } from 'react-admin';

const PEMDialog = (props: {
  pem: string,
  open: boolean,
  handleClose: () => void,
}) => {
  const { pem, open, handleClose } = props;
  const translate = useTranslate();
  const notify = useNotify();
  const copyTextToClipboard = async (text: string) => {
    try {
      await navigator.clipboard.writeText(text);
      notify(translate("cert.copySuccess"));
    } catch (err) {
      notify(translate("error.copyError"));
    }
  };
  return (
    <Dialog
      onClose={handleClose}
      aria-labelledby="customized-dialog-title"
      open={open}
      maxWidth={"md"}
    >
      <DialogTitle sx={{ m: 0, p: 2 }} id="customized-dialog-title">
        {translate("cert.certDataTitle")}
      </DialogTitle>
      <IconButton
        aria-label="close"
        onClick={handleClose}
        sx={{
          position: 'absolute',
          right: 8,
          top: 8,
          color: (theme) => theme.palette.grey[500],
        }}
      >
        <IoIosClose />
      </IconButton>
      <DialogContent dividers sx={{ whiteSpace: 'pre-line' }}>
        <Typography variant="body1">
          {pem}
        </Typography>
      </DialogContent>
      <DialogActions>
        <Button autoFocus startIcon={<FaCopy />} onClick={() => copyTextToClipboard(pem)}>
          {translate("cert.copy")}
        </Button>
      </DialogActions>
    </Dialog>
  );
}

export default PEMDialog;