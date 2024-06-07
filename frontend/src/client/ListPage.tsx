import * as React from 'react';
import {
  Datagrid,
  List,
  TextField,
  useTranslate
} from 'react-admin';
import {
  Box,
  Typography,
  Card,
  CardContent
} from '@mui/material';

const EmptyPage = () => {
  const translate = useTranslate();
  return (
    <Box sx={{ width: 1 }}>
      <Card sx={{ width: 1 }}>
        <CardContent sx={{ display: 'flex', justifyContent: 'center', alignItems: 'center' }}>
          <Typography variant="body1">
            {translate("client.empty")}
          </Typography>
        </CardContent>
      </Card>
    </Box>
  )
}
const ClientList = () => {
  const translate = useTranslate();
  return (
    <List
      resource="client"
      title={translate("client.title")}
      actions={false}
      sx={{ mt: 2 }}
      empty={<EmptyPage />}
    >
      <Datagrid bulkActionButtons={false} rowClick="edit">
        <TextField source="uid" label={"client.fields.uid"} />
        <TextField source="attributes" label={"client.fields.attributes"} />
      </Datagrid>
    </List>
  )
};

export default ClientList;