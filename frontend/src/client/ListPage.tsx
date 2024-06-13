import * as React from 'react';
import {
  Datagrid,
  List,
  TextField,
  useTranslate
} from 'react-admin';
import EmptyPage from '../layouts/EmptyPage';

const ClientList = () => {
  const translate = useTranslate();
  return (
    <List
      resource="client"
      title={translate("client.title")}
      actions={false}
      sx={{ mt: 2 }}
      empty={<EmptyPage message={translate("client.empty")}/>}
    >
      <Datagrid bulkActionButtons={false} rowClick="edit">
        <TextField source="uid" label={"client.fields.uid"} />
        <TextField source="status" label={"client.fields.status"} />
        <TextField source="attributes" label={"client.fields.attributes"} />
      </Datagrid>
    </List>
  )
};

export default ClientList;