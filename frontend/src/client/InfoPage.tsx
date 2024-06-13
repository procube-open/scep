import * as React from 'react';
import {
  Edit,
  InfiniteList,
  SimpleForm,
  TextInput,
  Datagrid,
  TextField,
  DateField,
  FunctionField,
  useDataProvider,
  required,
  useTranslate,
  useNotify,
  useRecordContext,
  RowClickFunction,
} from 'react-admin';
import {
  Box,
  Typography,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  Button,
  IconButton,
} from '@mui/material';
import DownloadButton from '../layouts/DownloadButton';
import BackButton from '../layouts/BackButton';
import { IoIosClose } from "react-icons/io";
import { FaCopy } from "react-icons/fa6";
import { FcCancel, FcApproval } from "react-icons/fc";
import { useFormContext, useWatch } from 'react-hook-form';
import { useParams } from "react-router-dom";
import EmptyPage from '../layouts/EmptyPage';

const InfoToolbar = () => {
  const dataProvider = useDataProvider();
  const form = useFormContext();
  const { formState: { isValid } } = form;
  const translate = useTranslate();
  return (
    <Box sx={{
      display: "flex",
      justifyContent: "space-between",
      alignItems: "center",
    }}>
      <DownloadButton
        downloadProvider={() => dataProvider.pkcs12("cert", form.getValues())}
        filename={`${form.getValues().id}.p12`}
        color="primary"
        type="submit"
        disabled={!isValid}
        children={<Typography>{translate("cert.pkcs12Download")}</Typography>}
        isLinear={true}
        sx={{ mr: 1, pt: 3, width: 1 }}
      />
    </Box>
  )
}


const InfoActions = () => {
  return (
    <BackButton color={"inherit"} sx={{ mb: 1 }} />
  )
}
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
    <React.Fragment>
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
    </React.Fragment>
  );
}

const StatusError = () => {
  const record = useRecordContext();
  const translate = useTranslate();
  if (record.status === "ACTIVE") return null
  else return (
    <Typography variant="body2" color={"error"} children={translate("error.statusError")} />
  )
}
const validateDownload = (values: any) => {
  const errors: {
    [key: string]: string
  } = {};
  if (values.status !== "ACTIVE") {
    errors.status = 'error.statusError';
  }
  if (!values.secret) {
    errors.secret = 'error.secretError';
  }
  if (!values.password) {
    errors.password = 'error.passwordError';
  }

  return errors;
}
const ClientInfo = () => {
  const { uid } = useParams();
  const translate = useTranslate();
  const [open, setOpen] = React.useState(false);
  const [pem, setPem] = React.useState("");

  const handleClickOpen: RowClickFunction = (id: any, resource: string, record: any) => {
    setPem(record.cert_data);
    setOpen(true);
    return false
  };
  const handleClose = () => {
    setOpen(false);
  };
  return (
    <Box>
      <Edit
        id={uid}
        redirect={false}
        mutationMode="optimistic"
        mutationOptions={{}}
        resource="client"
        actions={<InfoActions />}
        sx={{ m: 1 }}
        title={uid}
      >
        <SimpleForm validate={validateDownload} toolbar={<InfoToolbar />} mode="onChange" reValidateMode="onChange">
          <Typography variant="h6">{translate("client.editTitle")}</Typography>
          <Box sx={{
            display: "flex",
            width: 1,
          }}>
            <TextInput
              source="uid"
              label={translate("client.fields.uid")}
              variant="outlined"
              defaultValue={uid}
              disabled
              sx={{ pr: 1 }}
            />
            <TextInput
              source="secret"
              label={translate("client.fields.secret")}
              validate={required()}
              helperText={translate("error.secretError")}
              type="password"
              variant="outlined"
              sx={{ pr: 1, width: "50%" }}
            />
          </Box>
          <TextInput
            source="password"
            label={translate("cert.password")}
            validate={required()}
            helperText={translate("error.passwordError")}
            type="password"
            variant="outlined"
            sx={{ pr: 1, width: "80%" }}
          />
          <StatusError />
        </SimpleForm>
      </Edit>
      <InfiniteList
        resource="cert"
        queryOptions={{ meta: { cn: uid } }}
        disableSyncWithLocation
        actions={false}
        sx={{
          mt: 1,
        }}
        title={<></>}
        empty={<EmptyPage message={translate("cert.empty")} />}
      >
        <Datagrid bulkActionButtons={false} rowClick={handleClickOpen}>
          <TextField source="serial" label={"cert.fields.serial"} />
          <FunctionField source="status" label={"cert.fields.status"} render={(record: any) => {
            if (record.status === "V") {
              return <FcApproval />
            } else {
              return <FcCancel />
            }
          }} />
          <DateField source="valid_from" locales="jp-JP" label={"cert.fields.valid_from"} />
          <DateField source="valid_till" label={"cert.fields.valid_till"} />
          <DateField source="revocation_date" showTime locales="jp-JP" label={"cert.fields.revocation_date"} />
        </Datagrid>
      </InfiniteList>
      <PEMDialog pem={pem} open={open} handleClose={handleClose} />
    </Box>
  )
};

export default ClientInfo;