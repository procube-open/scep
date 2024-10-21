import * as React from 'react';
import {
  Edit,
  SimpleForm,
  TextInput,
  useDataProvider,
  required,
  useTranslate,
  useRecordContext,
  RowClickFunction,
  useRefresh,
  useNotify,
} from 'react-admin';
import {
  Box,
  Typography,
  Button,
} from '@mui/material';
import { useFormContext } from 'react-hook-form';
import { useParams } from "react-router-dom";
import DownloadButton from '../../layouts/Buttons/DownloadButton';
import BackButton from '../../layouts/Buttons/BackButton';
import PEMDialog from './PEMDialog';
import CertList from './CertList';
import SecretInfo from './SecretInfo';
import { IsAdminContext } from '../../isAdminContext';

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
        children={<Typography sx={{ ml: 1 }}>{translate("cert.pkcs12Download")}</Typography>}
        isLinear={true}
        sx={{ mr: 1, pt: 3, width: 1 }}
      />
    </Box>
  )
}


const InfoActions = () => {
  return (
    <Box sx={{ display: "flex", justifyContent: "space-between", alignItems: "center", }}>
      <BackButton color={"inherit"} />
      <RevokeButton />
    </Box>
  )
}

const StatusError = () => {
  const record = useRecordContext();
  const translate = useTranslate();
  if (record.status === "ISSUABLE" || record.status == "UPDATABLE") return null
  else return (
    <Typography variant="body2" color={"error"} children={translate("error.statusError")} />
  )
}

const validateDownload = (values: any) => {
  const errors: {
    [key: string]: string
  } = {};
  if (values.status !== "ISSUABLE" && values.status !== "UPDATABLE") {
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

const RevokeButton = () => {
  const { adminMode } = React.useContext(IsAdminContext);
  const dataProvider = useDataProvider();
  const { uid } = useParams();
  const translate = useTranslate();
  const refresh = useRefresh();
  const notify = useNotify();
  const record = useRecordContext();
  const handleClick = () => {
    dataProvider.revoke("client", { uid: uid }).then(() => {
      notify('client.revoked', { type: 'info' });
      refresh();
    })
  }
  if (!adminMode) return null
  return (
    <Button
      variant="contained"
      onClick={handleClick}
      color="error"
      disabled={record.status === "INACTIVE"}
      children={translate("client.revoke")}
    />
  )
}

const ClientInfo = () => {
  const { uid } = useParams();
  const translate = useTranslate();
  const [open, setOpen] = React.useState(false);
  const [pem, setPem] = React.useState("");

  const { adminMode } = React.useContext(IsAdminContext);
  const handleClickOpen: RowClickFunction = (id, resource, record) => {
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
      {adminMode && <SecretInfo uid={uid} />}
      <CertList uid={uid} handleClickOpen={handleClickOpen} />
      <PEMDialog pem={pem} open={open} handleClose={handleClose} />
    </Box>
  )
};

export default ClientInfo;