import {
  DateField,
  Datagrid,
  FunctionField,
  TextField,
  InfiniteList,
  useTranslate,
} from "react-admin";
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
  )
}

export default CertList;