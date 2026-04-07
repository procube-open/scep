import * as React from 'react';
import {
  Datagrid,
  List,
  TextField,
  FunctionField,
  useTranslate
} from 'react-admin';
import {
  Typography,
  Button,
  Box,
  ButtonProps
} from '@mui/material';
import EmptyPage from '../../layouts/EmptyPage';
import { IsAdminContext } from '../../isAdminContext';
import CreateDialog from './CreateDialog';
import { IoPersonAddSharp } from "react-icons/io5";

const windowsManagedClientType = 'windows-msi';

const parseAttributes = (value: unknown): Record<string, unknown> | null => {
  if (typeof value !== 'string' || value.trim() === '') {
    return null;
  }

  try {
    const parsed = JSON.parse(value);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>;
    }
  } catch (error) {
    return null;
  }

  return null;
};

const AdminActions = (props: ButtonProps) => {
  return (
    <Button
      {...props}
      startIcon={<IoPersonAddSharp />}
      variant="contained"
      color="primary"
    />
  );
}

const ClientList = () => {
  const translate = useTranslate();
  const { adminMode } = React.useContext(IsAdminContext);
  const [open, setOpen] = React.useState(false);
  const handleClickOpen = () => {
    setOpen(true);
  };
  const handleClose = () => {
    setOpen(false);
  };
  return (
    <>
      <List
        resource="client"
        title={translate("client.title")}
        actions={adminMode ? <AdminActions onClick={handleClickOpen} >{translate("client.create")}</AdminActions> : false}
        sx={{ mt: 2 }}
        empty={<EmptyPage header={
          adminMode ? <Box sx={{ width: 1, display: "flex", justifyContent: "end" }}>
            <AdminActions onClick={handleClickOpen} >{translate("client.create")}</AdminActions>
          </Box> : null
        } message={translate("client.empty")} />}
      >
        <Datagrid bulkActionButtons={false} rowClick="edit">
          <TextField source="uid" label={"client.fields.uid"} />
          <FunctionField source="status" label={"client.fields.status"} render={(record: any) => {
            return <Typography variant="body2"> {translate(`client.status.${record.status}`)}</Typography>
          }} />
          <FunctionField source="attributes" label={"client.fields.managed_client_type"} render={(record: any) => {
            const attributes = parseAttributes(record.attributes);
            if (attributes?.managed_client_type === windowsManagedClientType) {
              return <Typography variant="body2">{translate('client.managedClientType.windows_msi')}</Typography>;
            }
            return <Typography variant="body2">{translate('client.managedClientType.none')}</Typography>;
          }} />
          <TextField source="attributes" label={"client.fields.attributes"} />
        </Datagrid>
      </List>
      <CreateDialog open={open} handleClose={handleClose} />
    </>
  )
};

export default ClientList;
