import * as React from 'react';
import {
  Datagrid,
  List,
  FunctionField,
  useTranslate,
  useDataProvider,
} from 'react-admin';
import { useLocation } from "react-router-dom";
import {
  Box,
  Typography,
  Link,
  Breadcrumbs,
} from '@mui/material';
import { FaRegFolder, FaFile } from "react-icons/fa";
import EmptyPage from '../layouts/EmptyPage';
import DownloadButton from '../layouts/Buttons/DownloadButton';

const humanFileSize = (bytes: any, si = false, dp = 1) => {
  const thresh = si ? 1000 : 1024;
  if (Math.abs(bytes) < thresh) {
    return bytes + ' B';
  }
  const units = si
    ? ['kB', 'MB', 'GB', 'TB', 'PB', 'EB', 'ZB', 'YB']
    : ['KiB', 'MiB', 'GiB', 'TiB', 'PiB', 'EiB', 'ZiB', 'YiB'];
  let u = -1;
  const r = 10 ** dp;
  do {
    bytes /= thresh;
    ++u;
  } while (Math.round(Math.abs(bytes) * r) / r >= thresh && u < units.length - 1);
  return bytes.toFixed(dp) + ' ' + units[u];
}

const PathBreadcrumb = (props: { path: Array<string> }) => {
  const { path } = props;
  let currentPath = "/";
  return <Breadcrumbs sx={{ display: "flex", flexWrap: "wrap", alignItems: "center", width: 1 }}>
    {path.map((p, i) => {
      currentPath += p + "/";
      return <Link key={`${i}-${p}`} href={`./#${currentPath}`} underline="hover" variant="body2">
        {p}
      </Link>
    })}
  </Breadcrumbs>
}

const ClientList = () => {
  const translate = useTranslate();
  const location = useLocation();
  const path = location.pathname;
  const paths = path.split("/").slice(1, -1);
  const dataProvider = useDataProvider();
  return (
    <List
      resource="files"
      title={translate("files.title")}
      actions={<PathBreadcrumb path={paths} />}
      queryOptions={{ meta: { path: paths } }}
      empty={<EmptyPage header={<PathBreadcrumb path={paths} />} message={translate("files.empty")} />}
      sx={{ mt: 2 }}
    >
      <Datagrid bulkActionButtons={false}>
        <FunctionField source="name" label={"files.fields.name"} render={(record: any) => {
          if (record.is_dir) {
            return <Box sx={{ display: "flex" }}>
              <FaRegFolder />
              <Link href={`./#${path}${record.name}/`} underline="hover" variant="body2" sx={{ pl: 1 }}>
                {record.name}
              </Link>
            </Box>
          } else {
            return <Box sx={{ display: "flex" }}>
              <FaFile />
              <Typography variant="body2" sx={{ pl: 1 }}>
                {record.name}
              </Typography>
            </Box>
          }
        }} />
        <FunctionField source="size" label={"files.fields.size"} render={(record: any) => {
          if (record.is_dir) {
            return "-"
          } else {
            return humanFileSize(record.size)
          }
        }} />
        <FunctionField label={"files.download"} render={(record: any) => {
          if (record.is_dir) {
            return null
          } else {
            const downloadPath = paths.slice(1).concat(record.name).join("/");
            return <DownloadButton
              downloadProvider={() => dataProvider.download("files", { path: downloadPath })}
              filename={record.name}
              color="primary"
              isLinear={false}
              type="button"
              sx={{ maxHeight: 20, maxWidth: "50%", ml: 1 }}
              disabled={false}
            />
          }
        }} />
      </Datagrid>
    </List>
  )
};

export default ClientList;