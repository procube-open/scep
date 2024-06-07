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
  Card,
  CardContent,
} from '@mui/material';
import DownloadButton from '../layouts/DownloadButton';
import BackButton from '../layouts/BackButton';
import { IoIosClose,IoMdCheckmark  } from "react-icons/io";
import { AiOutlineStop } from "react-icons/ai";
import { useFormContext } from 'react-hook-form';
import { useParams } from "react-router-dom";

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
          <Button autoFocus onClick={() => copyTextToClipboard(pem)}>
            {translate("cert.copy")}
          </Button>
        </DialogActions>
      </Dialog>
    </React.Fragment>
  );
}

const CertEmptyPage = () => {
  const translate = useTranslate();
  return (
    <Box sx={{ width: 1 }}>
      <Card sx={{ width: 1 }}>
        <CardContent sx={{ display: 'flex', justifyContent: 'center', alignItems: 'center' }}>
          <Typography variant="body1">
            {translate("cert.empty")}
          </Typography>
        </CardContent>
      </Card>
    </Box>
  )
}

const ClientInfo = () => {
  const { uid } = useParams();
  const translate = useTranslate();
  const [open, setOpen] = React.useState(false);
  const [pem, setPem] = React.useState("");
  const handleClickOpen: RowClickFunction = (id: any,
    resource: string,
    record: any) => {
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
        resource="client"
        actions={<InfoActions />}
        sx={{ m: 1 }}
        title={uid}
      >
        <SimpleForm toolbar={<InfoToolbar />} mode="onChange" reValidateMode="onChange">
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
              type="password"
              variant="outlined"
              sx={{ pr: 1, width: "50%" }}
            />
          </Box>
          <TextInput
            source="password"
            label={translate("cert.password")}
            validate={required()}
            type="password"
            variant="outlined"
            sx={{ pr: 1, width: "80%" }}
          />
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
        empty={<CertEmptyPage />}
      >
        <Datagrid bulkActionButtons={false} rowClick={handleClickOpen}>
          <TextField source="serial" label={"cert.fields.serial"} />
          <FunctionField source="status" label={"cert.fields.status"} render={(record: any) => {
            if (record.status === "V") {
              return <IoMdCheckmark />
            } else {
              return <AiOutlineStop />
            }
          }} />
          <DateField source="valid_from" label={"cert.fields.valid_from"} />
          <DateField source="valid_till" label={"cert.fields.valid_till"} />
        </Datagrid>
      </InfiniteList>
      <PEMDialog pem={pem} open={open} handleClose={handleClose} />
    </Box>
  )
};

export default ClientInfo;