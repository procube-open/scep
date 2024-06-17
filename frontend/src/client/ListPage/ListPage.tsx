import * as React from 'react';
import {
  Datagrid,
  List,
  TextField,
  useTranslate
} from 'react-admin';
import {
  Button,
  ButtonProps
} from '@mui/material';
import EmptyPage from '../../layouts/EmptyPage';
import { IsAdminContext } from '../../isAdminContext';
import CreateDialog from './CreateDialog';
import { IoPersonAddSharp } from "react-icons/io5";

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
        actions={adminMode ? <AdminActions children={translate("client.create")} onClick={handleClickOpen} /> : false}
        sx={{ mt: 2 }}
        hasCreate={false}
        empty={<EmptyPage message={translate("client.empty")} />}
      >
        <Datagrid bulkActionButtons={false} rowClick="edit">
          <TextField source="uid" label={"client.fields.uid"} />
          <TextField source="status" label={"client.fields.status"} />
          <TextField source="attributes" label={"client.fields.attributes"} />
        </Datagrid>
      </List>
      <CreateDialog open={open} handleClose={handleClose} />
    </>
  )
};

export default ClientList;