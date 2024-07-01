import {
  DateField,
  Datagrid,
  FunctionField,
  TextField,
  InfiniteList,
  useTranslate,
} from "react-admin";
import {
  Typography,
} from "@mui/material";
import { FcApproval, FcCancel } from "react-icons/fc";
import EmptyPage from "../../layouts/EmptyPage";

const CertList = (props: { uid: string | undefined, handleClickOpen: any }) => {
  const { uid, handleClickOpen } = props;
  const translate = useTranslate();
  return (
    <InfiniteList
      resource="cert"
      queryOptions={{ meta: { cn: uid } }}
      disableSyncWithLocation
      actions={<Typography variant="h6" sx={{ ml: 1, order: -1 }} children={translate("cert.listTitle")} />}
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
        <FunctionField source="valid_from" label={"cert.fields.valid_duration"} render={(record: any) => {
          return <Typography variant="body2">{new Date(record.valid_from).toLocaleString()} ~ {new Date(record.valid_till).toLocaleString()}</Typography>
        }} />
        <DateField source="revocation_date" showTime locales="jp-JP" label={"cert.fields.revocation_date"} />
      </Datagrid>
    </InfiniteList>
  )
}

export default CertList;